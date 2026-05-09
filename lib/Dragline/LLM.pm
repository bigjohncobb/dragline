package Dragline::LLM;
use strict;
use warnings;
use utf8;

use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);
use Dragline::Cost;
use Dragline::SSRF;

our $VERSION = '0.1.0';

my %COSTS = (
    'claude-sonnet-4-5' => { input => 0.003,   output => 0.015  },
    'qwen-plus'         => { input => 0.0008,  output => 0.002  },
    'qwen-turbo'        => { input => 0.00015, output => 0.0006 },
    'llama3'            => { input => 0.0,     output => 0.0    },
);

my %PROVIDER_ORDER = (
    chunk_summarisation => [
        { provider => 'qwen',      model => 'qwen-turbo'       },
        { provider => 'ollama',    model => 'llama3'            },
    ],
    section_synthesis => [
        { provider => 'qwen',      model => 'qwen-plus'        },
        { provider => 'ollama',    model => 'llama3'            },
    ],
    forward_assessment => [
        { provider => 'anthropic', model => 'claude-sonnet-4-5' },
        { provider => 'qwen',      model => 'qwen-plus'        },
        { provider => 'ollama',    model => 'llama3'            },
    ],
    executive_summary => [
        { provider => 'anthropic', model => 'claude-sonnet-4-5' },
        { provider => 'ollama',    model => 'llama3'            },
    ],
    risk_synthesis => [
        { provider => 'anthropic', model => 'claude-sonnet-4-5' },
        { provider => 'qwen',      model => 'qwen-plus'        },
        { provider => 'ollama',    model => 'llama3'            },
    ],
    doc_intelligence => [
        { provider => 'qwen',      model => 'qwen-plus'        },
        { provider => 'ollama',    model => 'llama3'            },
    ],
);

my @OLLAMA_ONLY = ({ provider => 'ollama', model => 'llama3' });

# Singleton HTTP client to prevent connection pool and socket churn
my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(120);
        $ua->request_timeout(120);
        $ua;
    };
}

sub complete {
    my ($dbh, $settings_getter, %args) = @_;

    my $task_type     = $args{task_type}     or die 'task_type required';
    my $system_prompt = $args{system_prompt} // '';
    my $user_prompt   = $args{user_prompt}   or die 'user_prompt required';
    my $max_tokens    = $args{max_tokens}    // 2048;
    my $target_id     = $args{target_id};
    my $job_id        = $args{job_id};

    my $airgap = $ENV{DRAGLINE_AIRGAP} ? 1 : 0;

    my $providers = $airgap
        ? \@OLLAMA_ONLY
        : ($PROVIDER_ORDER{$task_type} // \@OLLAMA_ONLY);

    my $ua = _ua();

    for my $entry (@$providers) {
        my $provider = $entry->{provider};
        my $model    = $entry->{model};

        my ($text, $in_tok, $out_tok);

        if ($provider eq 'anthropic') {
            my $api_key = $settings_getter->('anthropic_api_key') or next;
            ($text, $in_tok, $out_tok) = call_anthropic($ua, $api_key,
                system_prompt => $system_prompt,
                user_prompt   => $user_prompt,
                max_tokens    => $max_tokens,
            );
        }
        elsif ($provider eq 'qwen') {
            my $api_key = $settings_getter->('alibaba_api_key') or next;
            ($text, $in_tok, $out_tok) = call_qwen($ua, $api_key, $model,
                system_prompt => $system_prompt,
                user_prompt   => $user_prompt,
                max_tokens    => $max_tokens,
            );
        }
        elsif ($provider eq 'ollama') {
            my $base_url = $settings_getter->('ollama_base_url') // 'http://localhost:11434';
            ($text, $in_tok, $out_tok) = call_ollama($ua, $base_url,
                system_prompt => $system_prompt,
                user_prompt   => $user_prompt,
                max_tokens    => $max_tokens,
            );
        }

        unless (defined $text) {
            warn "LLM: provider=$provider model=$model failed for task_type=$task_type\n";
            next;
        }

        my $rates    = $COSTS{$model} // { input => 0.0, output => 0.0 };
        my $cost_usd = ($in_tok / 1000 * $rates->{input})
                     + ($out_tok / 1000 * $rates->{output});

        Dragline::Cost::record($dbh,
            provider      => $provider,
            operation     => 'llm',
            model         => $model,
            input_tokens  => $in_tok,
            output_tokens => $out_tok,
            cost_usd      => $cost_usd,
            target_id     => $target_id,
            job_id        => $job_id,
        );

        return ($text, $provider, $in_tok + $out_tok);
    }

    warn "LLM: all providers exhausted for task_type=$task_type\n";
    return (undef, undef, 0);
}

sub call_anthropic {
    my ($ua, $api_key, %args) = @_;

    my $url = 'https://api.anthropic.com/v1/messages';
    my ($ok, $reason) = Dragline::SSRF::validate($url);
    unless ($ok) {
        warn "LLM: SSRF blocked Anthropic URL: $reason\n";
        return (undef, 0, 0);
    }

    my $body = encode_json({
        model      => 'claude-sonnet-4-5',
        max_tokens => $args{max_tokens} // 2048,
        system     => $args{system_prompt},
        messages   => [{ role => 'user', content => $args{user_prompt} }],
    });

    my $tx = $ua->post($url =>
        {
            'x-api-key'         => $api_key,
            'anthropic-version' => '2023-06-01',
            'content-type'      => 'application/json',
        } => $body
    );

    my $res = $tx->result;
    unless ($res->is_success) {
        warn "LLM: Anthropic error " . $res->code . ": " . $res->body . "\n";
        return (undef, 0, 0);
    }

    my $data = decode_json($res->body);
    my $text = $data->{content}[0]{text}        // '';
    my $in   = $data->{usage}{input_tokens}      // 0;
    my $out  = $data->{usage}{output_tokens}     // 0;

    return ($text, $in, $out);
}

sub call_qwen {
    my ($ua, $api_key, $model, %args) = @_;

    my $url = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
    my ($ok, $reason) = Dragline::SSRF::validate($url);
    unless ($ok) {
        warn "LLM: SSRF blocked Qwen URL: $reason\n";
        return (undef, 0, 0);
    }

    my @messages;
    push @messages, { role => 'system', content => $args{system_prompt} }
        if defined $args{system_prompt} && $args{system_prompt} ne '';
    push @messages, { role => 'user', content => $args{user_prompt} };

    my $body = encode_json({
        model      => $model,
        max_tokens => $args{max_tokens} // 2048,
        messages   => \@messages,
    });

    my $tx = $ua->post($url =>
        {
            'Authorization' => "Bearer $api_key",
            'content-type'  => 'application/json',
        } => $body
    );

    my $res = $tx->result;
    unless ($res->is_success) {
        warn "LLM: Qwen error " . $res->code . ": " . $res->body . "\n";
        return (undef, 0, 0);
    }

    my $data = decode_json($res->body);
    my $text = $data->{choices}[0]{message}{content} // '';
    my $in   = $data->{usage}{prompt_tokens}          // 0;
    my $out  = $data->{usage}{completion_tokens}      // 0;

    return ($text, $in, $out);
}

sub call_ollama {
    my ($ua, $base_url, %args) = @_;

    my $url = "$base_url/api/chat";
    my ($ok, $reason) = Dragline::SSRF::validate($url);
    unless ($ok) {
        warn "LLM: SSRF blocked Ollama URL: $reason\n";
        return (undef, 0, 0);
    }

    my $body = encode_json({
        model    => 'llama3',
        stream   => \0,
        messages => [
            { role => 'system', content => $args{system_prompt} // '' },
            { role => 'user',   content => $args{user_prompt}         },
        ],
    });

    my $tx = $ua->post($url =>
        { 'content-type' => 'application/json' } => $body
    );

    my $res = $tx->result;
    unless ($res->is_success) {
        warn "LLM: Ollama error " . $res->code . ": " . $res->body . "\n";
        return (undef, 0, 0);
    }

    my $data = decode_json($res->body);
    my $text = $data->{message}{content} // '';

    return ($text, 0, 0);
}

1;
