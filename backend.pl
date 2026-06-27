#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Encode;
use Mojo::JSON qw(decode_json encode_json);
use File::Spec;

# Inaktivitäts-Timeout serverseitig deaktivieren
$ENV{MOJO_INACTIVITY_TIMEOUT} = 0;

app->secrets(['structured_extractor_secret_2026']);

# Globale CORS-Konfiguration
app->hook(before_dispatch => sub {
    my $c = shift;
    $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization');
    if ($c->req->method eq 'OPTIONS') {
        $c->render(text => '', status => 204);
        return;
    }
});

# API-Endpunkte und Modell-Konfiguration
my $api_key  = $ENV{VLLM_API_KEY}  // 'ap-XX';
my $endpoint = $ENV{VLLM_ENDPOINT} // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $model    = $ENV{VLLM_MODEL}    // 'gpt-oss-120b';

# --- PATCHBAY REST CONFIGURATION ---
my $patchbay_url = $ENV{PATCHBAY_URL} // 'http://10.210.21.201:3036';

# Mojo::UserAgent initialisieren
my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);

# JSON Schema Type Validator für Backend Self-Correction
sub validate_schema_node {
    my ($data, $schema) = @_;
    return "Schema configuration is missing" unless defined $schema;
    return undef unless defined $data;

    my $type = $schema->{type} // 'string';
    if ($type eq 'object') {
        return "Value must be a valid object structure" unless ref $data eq 'HASH';
        if (exists $schema->{required}) {
            foreach my $req (@{$schema->{required}}) {
                return "Missing required schema parameter: '$req'" unless exists $data->{$req};
            }
        }
        if (exists $schema->{properties}) {
            foreach my $prop (keys %{$data}) {
                if (exists $schema->{properties}{$prop}) {
                    my $err = validate_schema_node($data->{$prop}, $schema->{properties}{$prop});
                    return $err if $err;
                }
            }
        }
    } elsif ($type eq 'array') {
        return "Value must be an array" unless ref $data eq 'ARRAY';
        if (exists $schema->{items}) {
            foreach my $item (@$data) {
                my $err = validate_schema_node($item, $schema->{items});
                return $err if $err;
            }
        }
    } elsif ($type eq 'integer' || $type eq 'number') {
        return "Numeric type mismatch" if ref $data || $data !~ /^-?\d+\.?\d*$/;
    } elsif ($type eq 'string') {
        return "String type mismatch" if ref $data;
    }
    return undef;
}

# Splits text into character-bounded blocks
sub create_document_chunks {
    my ($text, $max_chunk_size) = @_;
    $max_chunk_size //= 3000;

    my @paragraphs = split(/(?:\r?\n){2,}/, $text);
    my @chunks;
    my $current = "";

    foreach my $para (@paragraphs) {
        if (length($current) + length($para) > $max_chunk_size) {
            push @chunks, $current if $current;
            $current = $para;
        } else {
            $current .= ($current ? "\n\n" : "") . $para;
        }
    }
    push @chunks, $current if $current;
    return \@chunks;
}

# Merges extracted nodes across chunks safely
sub merge_extracted_structures {
    my ($accumulated, $new_data, $user_schema) = @_;
    return unless ref $accumulated eq 'HASH' && ref $new_data eq 'HASH' && ref $user_schema eq 'HASH';

    foreach my $key (keys %{$user_schema->{properties}}) {
        my $type = $user_schema->{properties}{$key}{type} // 'string';
        if ($type eq 'array') {
            $accumulated->{$key} //= [];
            if (exists $new_data->{$key} && ref $new_data->{$key} eq 'ARRAY') {
                push @{$accumulated->{$key}}, @{$new_data->{$key}};
            }
        } else {
            if (exists $new_data->{$key} && defined $new_data->{$key} && $new_data->{$key} ne '') {
                $accumulated->{$key} //= $new_data->{$key};
            }
        }
    }
}

# Helper to recursively collect leaf paths from extracted JSON structures
sub collect_leaf_paths {
    my ($data, $prefix, $paths) = @_;
    $prefix //= '';
    
    if (ref $data eq 'HASH') {
        foreach my $k (keys %$data) {
            my $next_prefix = $prefix eq '' ? $k : "$prefix/$k";
            collect_leaf_paths($data->{$k}, $next_prefix, $paths);
        }
    } elsif (ref $data eq 'ARRAY') {
        for (my $i = 0; $i < scalar @$data; $i++) {
            my $next_prefix = $prefix eq '' ? $i : "$prefix/$i";
            collect_leaf_paths($data->[$i], $next_prefix, $paths);
        }
    } else {
        $paths->{$prefix} = $data;
    }
}

# Helper to resolve custom retrievalSource properties in nested JSON Schemas
sub get_retrieval_source_for_path {
    my ($schema, $path) = @_;
    return undef unless defined $schema;
    my @parts = split('/', $path);
    my $current = $schema;
    my $retrieval = undef;
    
    foreach my $part (@parts) {
        if (exists $current->{retrievalSource} && $current->{retrievalSource} ne '- none -' && $current->{retrievalSource} ne '') {
            $retrieval = $current->{retrievalSource};
        }
        
        if ($part =~ /^\d+$/) { # Array Index
            if (exists $current->{items}) {
                $current = $current->{items};
            } else {
                last;
            }
        } else { # Objekt-Attribut
            if (exists $current->{properties} && exists $current->{properties}{$part}) {
                $current = $current->{properties}{$part};
            } else {
                last;
            }
        }
    }
    
    if (defined $current && exists $current->{retrievalSource} && $current->{retrievalSource} ne '- none -' && $current->{retrievalSource} ne '') {
        $retrieval = $current->{retrievalSource};
    }
    
    return $retrieval;
}

# Helper to update a deep nested path inside hash/array structures in-place
sub update_value_at_path {
    my ($data, $path, $new_val) = @_;
    my @parts = split('/', $path);
    my $current = \$data;
    
    foreach my $part (@parts) {
        if (ref($$current) eq 'HASH') {
            $current = \($$current->{$part});
        } elsif (ref($$current) eq 'ARRAY') {
            if ($part =~ /^\d+$/) {
                $current = \($$current->[$part]);
            } else {
                return;
            }
        } else {
            return;
        }
    }
    $$current = $new_val;
}

# --- METADATA RETRIEVAL FOR FRONTEND POPUPS ---
get '/embedded_datasets' => sub {
    my $c = shift;
    
    my $target_url = "$patchbay_url/LLM/embedded_datasets";
    
    $c->app->log->debug("[Backend] Querying Patchbay directly: GET $target_url");
    
    $ua->get($target_url => sub {
        my ($ua, $tx_call) = @_;
        
        my @fallback_stores = ('- none -', 'TEXT2ATC', 'OPS2ICD', 'TEXT2ICD');

        if ($tx_call->result && $tx_call->result->is_success) {
            my $res = eval { decode_json($tx_call->result->body) };
            
            if ($res && ref $res eq 'ARRAY') {
                my @names = ('- none -');
                foreach my $item (@$res) {
                    if (ref $item eq 'HASH' && exists $item->{name}) {
                        push @names, $item->{name};
                    }
                }
                
                if (!grep { $_ eq 'atc' } @names) {
                    push @names, 'atc';
                }

                $c->app->log->debug("[Backend] Extracted datasets from Patchbay: @names");
                return $c->render(json => { items => \@names });
            }
        }
        
        my $err_msg = $tx_call->error ? $tx_call->error->{message} : "Connection or format error";
        $c->app->log->error("[Backend] Patchbay retrieval failed: $err_msg. Using local fallbacks.");
        
        return $c->render(json => {
            items => \@fallback_stores,
            error => $err_msg
        });
    });
};

# Definition der Routing-Instanz
my $r = app->routes;

post '/api/extract' => sub {
    my $c = shift;

    $c->inactivity_timeout(0);

    my $payload = $c->req->json;

    my $text        = $payload->{text} // '';
    my $user_schema = $payload->{schema};
    my $user_prompt = $payload->{prompt} // 'Extract entities.';
    my $sel_model   = $payload->{model} // $model;

    $c->app->log->debug("[Backend] Received extraction request. Text Length: " . length($text) . " chars.");

    unless ($text && $user_schema) {
        $c->app->log->error("[Backend] Extraction aborted: Missing 'text' or 'schema' parameters.");
        return $c->render(json => { error => "Missing 'text' or 'schema' parameters." }, status => 400);
    }

    my $tx = $c->render_later->tx;

    # Meta-Schema Wrapping target
    my $meta_schema = {
        type => 'object',
        properties => {
            extracted_data => $user_schema,
            source_mappings => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => {
                        field_path => { type => 'string' },
                        exact_text => { type => 'string' }
                    },
                    required => ['field_path', 'exact_text']
                }
            }
        },
        required => ['extracted_data', 'source_mappings']
    };

    my $chunks = create_document_chunks($text, 3500);
    my $merged_extracted = {};
    my @aggregated_highlights;
    my $chunk_offset_tracker = 0;

    my $active_endpoint = $endpoint;
    my $active_model    = $sel_model;
    my $headers         = { 'Authorization' => "Bearer $api_key", 'Content-Type' => 'application/json' };

    if ($sel_model eq 'ollama') {
        $active_endpoint = 'http://localhost:11434/v1/chat/completions';
        $active_model    = 'gemma4:26b-mlx';
        $headers         = { 'Content-Type' => 'application/json' };
    }

    $c->app->log->debug("[Backend] Selected Model: $sel_model (Mapping to: $active_model)");
    $c->app->log->debug("[Backend] Targeting Endpoint: $active_endpoint");

    my $meta_schema_json = encode_json($meta_schema);

    my $system_instruction = "You are an expert data extraction agent. You must analyze the input text and extract structured information strictly according to this JSON Schema:\n\n"
    . $meta_schema_json . "\n\n"
    . "Instructions:\n"
    . "1. Provide the extracted fields under the 'extracted_data' key matching the requested keys, types, and nestings.\n"
    . "2. Under 'source_mappings', provide an array of objects. Each object must have 'field_path' (string path to the field, e.g. 'patient_name' or 'prescriptions/0/drug_name') and 'exact_text' (the exact verbatim substring from the source text where this data was found).\n"
    . "3. Respond with a single, valid JSON object matching the schema. Do not invent new fields or keys that are not defined in the schema properties.";

    # Sequential processing loop
    my $process_chunk;
    $process_chunk = sub {
        my $chunk_idx = shift;

        if ($chunk_idx >= @$chunks) {
            $c->app->log->debug("[Backend] Completed LLM processing. Commencing REST Dense Retrieval on Patchbay...");

            my $leaf_paths = {};
            collect_leaf_paths($merged_extracted, '', $leaf_paths);
            
            my @retrievals;
            foreach my $path (keys %$leaf_paths) {
                my $ret_source = get_retrieval_source_for_path($user_schema, $path);
                if ($ret_source && $ret_source ne '- none -' && $ret_source ne '') {
                    push @retrievals, {
                        path    => $path,
                        dataset => $ret_source,
                        value   => $leaf_paths->{$path}
                    };
                }
            }
            
            if (@retrievals) {
                # Sicherheits-Timeout für synchrone REST-Calls (Mojo-Standard)
                my $sync_ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
                
                foreach my $ret (@retrievals) {
                    my $path    = $ret->{path};
                    my $dataset = $ret->{dataset};
                    my $val     = $ret->{value};
                    
                    $c->app->log->debug("[Backend] Dispatching SYNCHRONOUS REST Query to Patchbay: $patchbay_url/LLM/get_matches_from_dataset_named/$dataset ($val)");
                    
                    my $tx_call = eval {
                        $sync_ua->post("$patchbay_url/LLM/get_matches_from_dataset_named/$dataset?top_k=1"
                            => {Accept => '*/*'}
                            => encode('UTF-8', $val)
                        );
                    };

                    if ($@) {
                        $c->app->log->error("[Backend] Exception during retrieval call for '$path': $@");
                        next;
                    }
                    
                    if ($tx_call && $tx_call->result && $tx_call->result->is_success) {
                        my $body = $tx_call->result->body;
                        if (defined $body) {
                            $body =~ s/^\s+//;
                            $body =~ s/\s+$//;
                        }
                        
                        $c->app->log->debug("[Backend] Patchbay Raw Response for '$path': '$body'");
                        
                        if (!defined $body || $body eq '') {
                            $c->app->log->warn("[Backend] Patchbay returned empty response for '$path'");
                            next;
                        }
                        
                        my $res = eval { decode_json($body) };
                        if ($@) {
                            # Fallback 1: Falls kein valides JSON geliefert wird, Roh-Inhalt nutzen
                            $c->app->log->debug("[Backend] JSON decode failed ($@). Using raw body as fallback.");
                            update_value_at_path($merged_extracted, $path, $body);
                        } else {
                            if (!defined $res) {
                                $c->app->log->warn("[Backend] Decoded JSON is undefined for '$path'");
                            } elsif (!ref $res) {
                                # Fallback 2: Ergebnis ist ein JSON-Skalar (z.B. "R03AL01" in Anführungszeichen)
                                $c->app->log->debug("[Backend] Patchbay parsed scalar value for '$path' -> '$res'");
                                update_value_at_path($merged_extracted, $path, $res);
                            } elsif (ref $res eq 'HASH') {
                                # Fallback 3: Objekt-Antwort mit verschiedenen typischen Key-Varianten (label bevorzugt)
                                my $match = $res->{label} // $res->{match} // $res->{code} // $res->{id} // $res->{text} // $res->{name} // $res->{payload};
                                if (defined $match) {
                                    $c->app->log->debug("[Backend] Patchbay Hash Hit for '$path' -> '$match'");
                                    update_value_at_path($merged_extracted, $path, $match);
                                } else {
                                    $c->app->log->warn("[Backend] Patchbay Hash has no recognized keys for '$path'");
                                }
                            } elsif (ref $res eq 'ARRAY' && @$res) {
                                # Fallback 4: Array-Antworten (direkte Strings oder Objekte)
                                my $best_item = $res->[0];
                                if (ref $best_item eq 'HASH') {
                                    my $match = $best_item->{label} // $best_item->{match} // $best_item->{code} // $best_item->{id} // $best_item->{text} // $best_item->{name} // $best_item->{payload};
                                    if (defined $match) {
                                        $c->app->log->debug("[Backend] Patchbay Array Hash Hit for '$path' -> '$match'");
                                        update_value_at_path($merged_extracted, $path, $match);
                                    } else {
                                        $c->app->log->warn("[Backend] Patchbay Array Item Hash has no recognized keys for '$path'");
                                    }
                                } elsif (!ref $best_item) {
                                    $c->app->log->debug("[Backend] Patchbay Array Scalar Hit for '$path' -> '$best_item'");
                                    update_value_at_path($merged_extracted, $path, $best_item);
                                }
                            } else {
                                $c->app->log->warn("[Backend] Unhandled reference type for '$path': " . ref($res));
                            }
                        }
                    } else {
                        my $err_msg = ($tx_call && $tx_call->error) ? $tx_call->error->{message} : "Connection timeout or host unreachable";
                        $c->app->log->error("[Backend] Patchbay REST call failed for '$path' on '$patchbay_url': $err_msg");
                    }
                }
            }
            
            if ($c->tx) {
                return $c->render(json => {
                    extracted_data => $merged_extracted,
                    highlights     => \@aggregated_highlights
                });
            } else {
                $c->app->log->warn("[Backend] Client disconnected before final response could be delivered.");
            }
            return;
        }

        my $chunk_text = $chunks->[$chunk_idx];
        my $attempt = 0;
        my $max_attempts = 3;
        my $last_validation_error = "";

        my $run_attempt;
        $run_attempt = sub {
            my $feedback_msg = "";
            if ($last_validation_error) {
                $feedback_msg = "\n\n[WARNING: Previous extraction run failed structural validation:\n$last_validation_error\nPlease correct the output format, specifically matching the required schema keys.]";
            }

            my $api_payload = {
                model       => $active_model,
                messages    => [
                    { role => 'system', content => $system_instruction },
                    { role => 'user',   content => "CHUNK INPUT TEXT:\n---\n$chunk_text\n---\nPrompt: $user_prompt$feedback_msg" }
                ],
                temperature => 0.0,
                response_format => {
                    type => 'json_schema',
                    json_schema => {
                        name => "structured_extraction",
                        strict => \1,
                        schema => $meta_schema
                    }
                }
            };

            $c->app->log->debug("[Backend] Dispatching Chunk $chunk_idx (Attempt " . ($attempt + 1) . " of $max_attempts) to LLM...");

            $ua->post($active_endpoint => $headers => json => $api_payload => sub {
                my ($ua, $tx_call) = @_;

                if ($tx_call->result && $tx_call->result->is_success) {
                    my $res = eval { decode_json($tx_call->result->body) } // {};
                    my $content = $res->{choices}[0]{message}{content} // '';

                    $c->app->log->debug("[Backend] --- RAW LLM OUTPUT FOR CHUNK $chunk_idx ---");
                    $c->app->log->debug($content);
                    $c->app->log->debug("[Backend] -----------------------------------------");

                    my $parsed = eval { decode_json($content) };
                    if ($@ && $content =~ /^\s*```(?:json)?\s*(.*?)\s*```/is) {
                        $parsed = eval { decode_json($1) };
                    }

                    if ($parsed) {
                        my $val_err = validate_schema_node($parsed->{extracted_data}, $user_schema);
                        if (!$val_err) {
                            $c->app->log->debug("[Backend] Chunk $chunk_idx successfully validated against schema.");

                            merge_extracted_structures($merged_extracted, $parsed->{extracted_data}, $user_schema);

                            my $source_mappings = $parsed->{source_mappings} // [];
                            foreach my $mapping (@$source_mappings) {
                                my $f_path = $mapping->{field_path};
                                my $match  = $mapping->{exact_text};
                                next unless defined $match && $match ne '';

                                my $pos = index($chunk_text, $match);
                                if ($pos != -1) {
                                    push @aggregated_highlights, {
                                        field_path => $f_path,
                                        exact_text => $match,
                                        offset     => $chunk_offset_tracker + $pos,
                                        length     => length($match)
                                    };
                                }
                            }

                            $chunk_offset_tracker += length($chunk_text) + 2;
                            $process_chunk->($chunk_idx + 1);
                        } else {
                            $attempt++;
                            $last_validation_error = $val_err;
                            $c->app->log->warn("[Backend] Chunk $chunk_idx failed validation: $val_err");
                            if ($attempt < $max_attempts) {
                                $run_attempt->();
                            } else {
                                $c->app->log->error("[Backend] Maximum attempts reached on chunk $chunk_idx. Skipping chunk.");
                                $chunk_offset_tracker += length($chunk_text) + 2;
                                $process_chunk->($chunk_idx + 1);
                            }
                        }
                    } else {
                        $attempt++;
                        $last_validation_error = "Could not parse output as valid JSON.";
                        $c->app->log->warn("[Backend] Chunk $chunk_idx JSON parser failed on output.");
                        if ($attempt < $max_attempts) {
                            $run_attempt->();
                        } else {
                            $c->app->log->error("[Backend] Maximum JSON parsing attempts reached on chunk $chunk_idx. Skipping chunk.");
                            $chunk_offset_tracker += length($chunk_text) + 2;
                            $process_chunk->($chunk_idx + 1);
                        }
                    }
                } else {
                    my $err_msg = $tx_call->error ? $tx_call->error->{message} : "Unknown API connection error";
                    $c->app->log->error("[Backend] API Endpoint call failed: $err_msg");
                    $chunk_offset_tracker += length($chunk_text) + 2;
                    $process_chunk->($chunk_idx + 1);
                }
            });
        };

        $run_attempt->();
    };

    $process_chunk->(0);
};

# Hypnotoad-Konfiguration auf Port 4005
app->config(hypnotoad => {listen => ['http://*:4005'], workers => 4, heartbeat_timeout => 12000, inactivity_timeout => 12000});
app->start;
