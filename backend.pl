#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::UserAgent;
use Encode;
use Mojo::JSON qw(decode_json encode_json);
use File::Spec;

# Disable inactivity timeout server-side
$ENV{MOJO_INACTIVITY_TIMEOUT} = 0;

app->secrets(['structured_extractor_secret_2026']);

# Global CORS Configuration
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

# API Endpoints and Model Configuration
my $api_key  = $ENV{VLLM_API_KEY}  // 'ap-XX';
my $endpoint = $ENV{VLLM_ENDPOINT} // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $model    = $ENV{VLLM_MODEL}    // 'gpt-oss-120b';

# --- PATCHBAY REST CONFIGURATION ---
my $patchbay_url = $ENV{PATCHBAY_URL} // 'http://10.210.21.201:3036';

# Default configuration for grounding validation (0 = Disabled, 1 = Enabled)
my $default_enforce_grounding = $ENV{ENFORCE_GROUNDING} // 0;

# Initialize Mojo::UserAgent
my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);

# JSON Schema Type Validator for Backend Self-Correction
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

# Secondary Grounding Validator to detect and reject hallucinations
sub verify_grounding_and_mappings {
    my ($extracted_data, $source_mappings, $source_text) = @_;
    return undef unless defined $source_text && $source_text ne '';

    my %valid_mapped_paths;

    # 1. Verify that all declared verbatim source mappings actually exist in the text
    foreach my $mapping (@$source_mappings) {
        my $path  = $mapping->{field_path};
        my $exact = $mapping->{exact_text};
        next unless defined $path && defined $exact && $exact ne '';

        # Case-insensitive substring check within the raw source text
        if (index(lc($source_text), lc($exact)) != -1) {
            $valid_mapped_paths{$path} = $exact;
        } else {
            return "Grounding Violation: The verbatim mapping '$exact' declared for field path '$path' is missing from the source text.";
        }
    }

    # 2. Inspect extracted leaf nodes to verify they are grounded in the source text
    my $leaf_paths = {};
    collect_leaf_paths($extracted_data, '', $leaf_paths);

    foreach my $path (keys %$leaf_paths) {
        my $val = $leaf_paths->{$path};
        next unless defined $val && $val ne '';

        # Skip numbers, booleans, or very short codes which are often normalized/formatted
        next if $val =~ /^(?:true|false|\d+|\d+\.\d+)$/i;

        # If there is no corresponding verbatim highlight mapping, verify the value itself is present
        if (!exists $valid_mapped_paths{$path}) {
            if (index(lc($source_text), lc($val)) == -1) {
                # Only flag longer string values to avoid blocking valid short variations
                if (length($val) > 4) {
                    return "Grounding Violation: Extracted value '$val' at field path '$path' is not present in the source text and has no valid text mapping.";
                }
            }
        }
    }

    return undef; # Grounding validation passed successfully
}

# Recursively cleans custom GUI keys from schemas to prevent LLM strict-mode validation failures
sub clean_schema_for_llm {
    my ($schema) = @_;
    return unless defined $schema;
    return $schema unless ref $schema;

    if (ref $schema eq 'HASH') {
        my $cleaned = {};
        # Standard schema keywords allowed under typical strict validation constraints
        my %allowed = map { $_ => 1 } qw(type properties items required description enum);

        foreach my $k (keys %$schema) {
            if ($allowed{$k}) {
                if ($k eq 'properties') {
                    $cleaned->{$k} = {};
                    foreach my $prop (keys %{$schema->{properties}}) {
                        $cleaned->{$k}{$prop} = clean_schema_for_llm($schema->{properties}{$prop});
                    }
                } elsif ($k eq 'items') {
                    $cleaned->{$k} = clean_schema_for_llm($schema->{items});
                } else {
                    $cleaned->{$k} = $schema->{$k};
                }
            }
        }

        # Ensure schema strictness guarantees are met
        if (($cleaned->{type} // '') eq 'object') {
            $cleaned->{additionalProperties} = \0 unless exists $cleaned->{additionalProperties};
            if (exists $cleaned->{properties}) {
                my @prop_keys = keys %{$cleaned->{properties}};
                $cleaned->{required} = \@prop_keys unless exists $cleaned->{required};
            }
        }
        return $cleaned;
    } elsif (ref $schema eq 'ARRAY') {
        return [ map { clean_schema_for_llm($_) } @$schema ];
    }
    return $schema;
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

# Helper to resolve custom vector search mapping keys in nested JSON Schemas
sub get_retrieval_source_for_path {
    my ($schema, $path) = @_;
    return undef unless defined $schema;
    my @parts = split('/', $path);
    my $current = $schema;
    my $retrieval = undef;

    foreach my $part (@parts) {
        # Check alternative parameters generated by tree visualizers
        foreach my $key_variant ('retrievalSource', 'codingViaVectorsearch', 'coding_vectorsearch', 'coding') {
            if (exists $current->{$key_variant} && $current->{$key_variant} ne '- none -' && $current->{$key_variant} ne '') {
                $retrieval = $current->{$key_variant};
            }
        }

        if ($part =~ /^\d+$/) { # Array Index
            if (exists $current->{items}) {
                $current = $current->{items};
            } else {
                last;
            }
        } else { # Object Property
            if (exists $current->{properties} && exists $current->{properties}{$part}) {
                $current = $current->{properties}{$part};
            } else {
                last;
            }
        }
    }

    foreach my $key_variant ('retrievalSource', 'codingViaVectorsearch', 'coding_vectorsearch', 'coding') {
        if (defined $current && exists $current->{$key_variant} && $current->{$key_variant} ne '- none -' && $current->{$key_variant} ne '') {
            $retrieval = $current->{$key_variant};
        }
    }

    return $retrieval;
}

# Helper to update a deeply nested path inside structures in-place
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

# --- METADATA RETRIEVAL FOR FRONTEND ---
get '/embedded_datasets' => sub {
    my $c = shift;

    my $target_url = "$patchbay_url/LLM/embedded_datasets";
    $c->app->log->debug("[Backend] Querying Vectorsearch datasets: GET $target_url");

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

                # Verify clinical defaults are present
                foreach my $req_store ('TEXT2ATC', 'TEXT2ICD') {
                    push @names, $req_store unless grep { $_ eq $req_store } @names;
                }

                $c->app->log->debug("[Backend] Found vectorsearch datasets: @names");
                return $c->render(json => { items => \@names });
            }
        }

        my $err_msg = $tx_call->error ? $tx_call->error->{message} : "Connection or format error";
        $c->app->log->error("[Backend] Vectorsearch database retrieval failed: $err_msg. Using fallbacks.");
        return $c->render(json => { items => \@fallback_stores, error => $err_msg });
    });
};

# Definition of Routing
my $r = app->routes;

post '/api/extract' => sub {
    my $c = shift;
    $c->inactivity_timeout(0);

    my $payload     = $c->req->json;
    my $text        = $payload->{text} // '';
    my $user_schema = $payload->{schema};
    my $user_prompt = $payload->{prompt} // 'Extract entities.';
    my $sel_model   = $payload->{model} // $model;

    # Extract grounding enforcement flag from incoming JSON payload (overriding the env default if present)
    my $enforce_grounding = $payload->{enforce_grounding} // $default_enforce_grounding;

    $c->app->log->debug("[Backend] Extraction Request Received. Input: " . length($text) . " characters.");
    $c->app->log->debug("[Backend] Grounding Validation Enforced: " . ($enforce_grounding ? 'YES' : 'NO'));

    unless ($text && $user_schema) {
        $c->app->log->error("[Backend] Extraction aborted: Missing required payload properties.");
        return $c->render(json => { error => "Missing 'text' or 'schema' parameters." }, status => 400);
    }

    my $tx = $c->render_later->tx;

    # Stripped Schema version for LLM context API limits / compatibility
    my $clean_user_schema = clean_schema_for_llm($user_schema);

    # Meta-Schema Construction
    my $meta_schema = {
        type => 'object',
        properties => {
            extracted_data => $clean_user_schema,
            source_mappings => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => {
                        field_path => { type => 'string' },
                        exact_text => { type => 'string' }
                    },
                    required => ['field_path', 'exact_text'],
                    additionalProperties => \0
                }
            }
        },
        required => ['extracted_data', 'source_mappings'],
        additionalProperties => \0
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

    $c->app->log->debug("[Backend] Targets: Model '$active_model' at URL: $active_endpoint");

    my $meta_schema_json = encode_json($meta_schema);
    my $system_instruction = "You are an expert data extraction agent. You must analyze the input text and extract structured information strictly according to this JSON Schema:\n\n"
    . $meta_schema_json . "\n\n"
    . "Instructions:\n"
    . "1. Provide the extracted fields under the 'extracted_data' key matching the requested keys, types, and nestings.\n"
    . "2. Under 'source_mappings', provide an array of objects. Each object must have 'field_path' (string path to the field, e.g. 'patient_name' or 'prescriptions/0/drug_name') and 'exact_text' (the exact verbatim substring from the source text where this data was found).\n"
    . "3. Respond with a single, valid JSON object matching the schema. Do not invent new fields or keys that are not defined in the schema properties.";

    # Sequential chunk processing
    my $process_chunk;
    $process_chunk = sub {
        my $chunk_idx = shift;

        if ($chunk_idx >= @$chunks) {
            $c->app->log->debug("[Backend] All chunks completed. Commencing semantic vector-search mapping...");

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
                my $sync_ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

                foreach my $ret (@retrievals) {
                    my $path    = $ret->{path};
                    my $dataset = $ret->{dataset};
                    my $val     = $ret->{value};

                    $c->app->log->debug("[Backend] Coding '$val' at path '$path' via dataset '$dataset'...");

                    my $tx_call = eval {
                        $sync_ua->post("$patchbay_url/LLM/get_matches_from_dataset_named/$dataset?top_k=1"
                        => {Accept => '*/*'}
                        => encode('UTF-8', $val)
                        );
                    };

                    if ($@) {
                        $c->app->log->error("[Backend] Exception on vector search: $@");
                        next;
                    }

                    if ($tx_call && $tx_call->result && $tx_call->result->is_success) {
                        my $body = $tx_call->result->body;
                        if (defined $body) {
                            $body =~ s/^\s+//; $body =~ s/\s+$//;
                        }

                        if (!defined $body || $body eq '') {
                            $c->app->log->warn("[Backend] Empty return for '$path'");
                            next;
                        }

                        my $res = eval { decode_json($body) };
                        if ($@) {
                            $c->app->log->debug("[Backend] Mapped raw scalar value for '$path' -> '$body'");
                            update_value_at_path($merged_extracted, $path, $body);
                        } else {
                            if (!defined $res) {
                                $c->app->log->warn("[Backend] Undefined JSON decoded for path '$path'");
                            } elsif (!ref $res) {
                                $c->app->log->debug("[Backend] Parsed coded scalar for '$path' -> '$res'");
                                update_value_at_path($merged_extracted, $path, $res);
                            } elsif (ref $res eq 'HASH') {
                                my $match = $res->{label} // $res->{match} // $res->{code} // $res->{id} // $res->{text};
                                if (defined $match) {
                                    $c->app->log->debug("[Backend] Mapped code for '$path' -> '$match'");
                                    update_value_at_path($merged_extracted, $path, $match);
                                }
                            } elsif (ref $res eq 'ARRAY' && @$res) {
                                my $best_item = $res->[0];
                                if (ref $best_item eq 'HASH') {
                                    my $match = $best_item->{label} // $best_item->{match} // $best_item->{code} // $best_item->{id};
                                    if (defined $match) {
                                        $c->app->log->debug("[Backend] Mapped array-object match for '$path' -> '$match'");
                                        update_value_at_path($merged_extracted, $path, $match);
                                    }
                                } elsif (!ref $best_item) {
                                    $c->app->log->debug("[Backend] Mapped array scalar match for '$path' -> '$best_item'");
                                    update_value_at_path($merged_extracted, $path, $best_item);
                                }
                            }
                        }
                    } else {
                        my $err_msg = ($tx_call && $tx_call->error) ? $tx_call->error->{message} : "Connection timeout";
                        $c->app->log->error("[Backend] Vectorsearch request failed: $err_msg");
                    }
                }
            }

            if ($c->tx) {
                return $c->render(json => {
                    extracted_data => $merged_extracted,
                    highlights     => \@aggregated_highlights
                });
            } else {
                $c->app->log->warn("[Backend] Client disconnected before final payload was output.");
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
                $feedback_msg = "\n\n[WARNING: Previous extraction run failed structural or grounding validation:\n$last_validation_error\nPlease correct the output format, specifically matching the required schema keys or ensuring extracted data is grounded strictly in the source text.]";
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
                        # Step 1: Validate Type structures against JSON Schema
                        my $val_err = validate_schema_node($parsed->{extracted_data}, $user_schema);

                        # Step 2: Validate grounding if flags are set to active
                        if (!$val_err && $enforce_grounding) {
                            my $source_mappings = $parsed->{source_mappings} // [];
                            $val_err = verify_grounding_and_mappings($parsed->{extracted_data}, $source_mappings, $chunk_text);
                        }

                        if (!$val_err) {
                            $c->app->log->debug("[Backend] Chunk $chunk_idx successfully validated and grounded.");

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

# Hypnotoad configuration on Port 4005
app->config(hypnotoad => {listen => ['http://*:4005'], workers => 4, heartbeat_timeout => 12000, inactivity_timeout => 12000});
app->start;
