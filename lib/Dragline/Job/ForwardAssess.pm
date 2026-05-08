package Dragline::Job::ForwardAssess;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::LLM;
use JSON::PP qw(encode_json decode_json);
use Data::UUID;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "ForwardAssess: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $settings_getter = sub {
        my ($key) = @_;
        my $row = $dbh->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key=?},
            undef, $key,
        );
        return undef unless $row;
        return undef unless defined($row->{value}) && $row->{value} ne '';
        return $row->{is_encrypted}
            ? $self->app->decrypt_value($row->{value})
            : $row->{value};
    };

    my $dossier = $dbh->selectrow_hashref(
        q{SELECT id FROM dossiers WHERE target_id = ? AND status = 'current'},
        undef, $target_id,
    );
    die "ForwardAssess: no current dossier for target $target_id" unless $dossier;
    my $dossier_id = $dossier->{id};

    my $sections = $dbh->selectall_arrayref(
        q{SELECT section_name, content FROM dossier_sections
          WHERE dossier_id = ? AND section_number IN (2,4,6,8)
          ORDER BY section_number},
        { Slice => {} }, $dossier_id,
    );

    my $context = '';
    for my $sec (@$sections) {
        $context .= "## $sec->{section_name}\n\n$sec->{content}\n\n";
    }

    my $sys = "You are a senior intelligence analyst. Based on the provided dossier sections, "
        . "produce a structured forward assessment as a single JSON object. Do not include any "
        . "prose before or after the JSON. The JSON must have exactly these top-level keys:\n\n"
        . "base_case: { summary, probability (high|medium|low), key_assumptions[], indicators[] }\n"
        . "downside_case: { summary, probability (high|medium|low), triggers[], indicators[] }\n"
        . "upside_case: { summary, probability (high|medium|low), conditions[], indicators[] }\n"
        . "recommended_posture: one of monitor, engage, avoid, investigate, escalate\n"
        . "posture_rationale: one or two sentences explaining the posture recommendation\n"
        . "executive_actions: array of plain-English action strings\n"
        . "watch_list: array of {item, reason} objects (may be omitted)\n";

    my ($text, $provider, $tokens) = Dragline::LLM::complete(
        $dbh, $settings_getter,
        task_type     => 'forward_assessment',
        system_prompt => $sys,
        user_prompt   => $context,
        max_tokens    => 2048,
        target_id     => $target_id,
    );

    unless (defined $text && length $text) {
        die "ForwardAssess: LLM returned empty response for target $target_id";
    }

    my $data = eval { decode_json($text) };
    unless ($data) {
        die "ForwardAssess: JSON parse failed for target $target_id. Raw response:\n$text\nError: $@";
    }

    my $posture = $data->{recommended_posture} // '';
    my %valid_posture = map { $_ => 1 } qw(monitor engage avoid investigate escalate);
    unless ($valid_posture{$posture}) {
        die "ForwardAssess: invalid recommended_posture '$posture' for target $target_id";
    }

    my $id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO forward_assessments
            (id, target_id, dossier_id, base_case, downside_case, upside_case,
             recommended_posture, posture_rationale, executive_actions, watch_list, model_used)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(target_id) DO UPDATE SET
            dossier_id          = excluded.dossier_id,
            base_case           = excluded.base_case,
            downside_case       = excluded.downside_case,
            upside_case         = excluded.upside_case,
            recommended_posture = excluded.recommended_posture,
            posture_rationale   = excluded.posture_rationale,
            executive_actions   = excluded.executive_actions,
            watch_list          = excluded.watch_list,
            model_used          = excluded.model_used,
            updated_at          = datetime('now')},
        undef,
        $id, $target_id, $dossier_id,
        encode_json($data->{base_case}),
        encode_json($data->{downside_case}),
        encode_json($data->{upside_case}),
        $posture,
        $data->{posture_rationale} // '',
        encode_json($data->{executive_actions}),
        (defined $data->{watch_list} ? encode_json($data->{watch_list}) : undef),
        $provider // 'unknown',
    );

    my $target = $dbh->selectrow_hashref(
        q{SELECT canonical_name FROM targets WHERE id = ?},
        undef, $target_id,
    );
    my $canonical = $target ? $target->{canonical_name} : $target_id;

    my $ce_id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO change_events
            (id, target_id, event_type, summary, severity)
          VALUES (?, ?, 'dossier_updated', ?, 'info')},
        undef, $ce_id, $target_id,
        "Forward assessment updated for $canonical — posture: $posture",
    );

    $log->info("ForwardAssess: completed for target $target_id (posture: $posture)");
}

1;
