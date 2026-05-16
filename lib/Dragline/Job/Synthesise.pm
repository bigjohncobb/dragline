package Dragline::Job::Synthesise;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::LLM;
use Dragline::Job::Steps;
use Data::UUID;
use JSON::PP qw(encode_json);

my $_uuid = Data::UUID->new;

my @SECTIONS = (
    { number => 1,  name => 'Identity and Overview',     task_type => 'section_synthesis'  },
    { number => 2,  name => 'Key People',                task_type => 'section_synthesis'  },
    { number => 3,  name => 'Organisational Structure',  task_type => 'section_synthesis'  },
    { number => 4,  name => 'Operational Profile',       task_type => 'section_synthesis'  },
    { number => 5,  name => 'Document Archive',          task_type => 'section_synthesis'  },
    { number => 6,  name => 'Event Timeline',            task_type => 'section_synthesis'  },
    { number => 7,  name => 'Media and Sentiment',       task_type => 'section_synthesis'  },
    { number => 8,  name => 'Risk and Flags',            task_type => 'section_synthesis'  },
    { number => 9,  name => 'Financial Instruments',     task_type => 'section_synthesis'  },
    { number => 10, name => 'Forward Assessment',        task_type => 'forward_assessment' },
);

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "Synthesise: target_id required";

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

    # Get or create dossier, set status='generating'
    my $new_dossier_id = $_uuid->create_str;
    $dbh->do(
        q{INSERT INTO dossiers (id, target_id, status)
          VALUES (?, ?, 'generating')
          ON CONFLICT(target_id) DO UPDATE SET
            status     = 'generating',
            updated_at = datetime('now')},
        undef, $new_dossier_id, $target_id,
    );
    my $dossier_id = $dbh->selectrow_array(
        q{SELECT id FROM dossiers WHERE target_id=?},
        undef, $target_id,
    );

    # Checkpoint clear decision
    my $force_sections = $args->{force_sections};
    if ($self->retries == 0 && !$force_sections) {
        Dragline::Job::Steps::clear($dbh, 'dossier', $dossier_id);
    }

    my %force_set;
    if ($force_sections) {
        %force_set = map { $_ => 1 } @$force_sections;
    }

    my $ok = eval {
        # ---- Map phase ----
        my $rows = $dbh->selectall_arrayref(
            q{SELECT content_text, source_url FROM raw_content
              WHERE target_id=?
              ORDER BY COALESCE(significance_tier, 999) DESC, created_at DESC},
            { Slice => {} }, $target_id,
        );

        my @chunk_summaries;
        my $chunk_idx = 0;
        for my $row (@$rows) {
            my @chunks = _split_chunks($row->{content_text}, 2000);
            for my $chunk (@chunks) {
                my $step_name = "map_chunk_$chunk_idx";
                if (Dragline::Job::Steps::is_done($dbh, 'dossier', $dossier_id, $step_name)) {
                    my $stored = Dragline::Job::Steps::get($dbh, 'dossier', $dossier_id, $step_name);
                    push @chunk_summaries, $stored->{summary}
                        if defined $stored && defined $stored->{summary};
                }
                else {
                    my ($summary) = Dragline::LLM::complete(
                        $dbh, $settings_getter,
                        task_type     => 'chunk_summarisation',
                        system_prompt => 'Summarise the following content from a business intelligence'
                            . ' report. Be concise and factual. Extract key facts, names, dates,'
                            . ' and figures.',
                        user_prompt   => $chunk,
                        max_tokens    => 500,
                        target_id     => $target_id,
                    );
                    if (defined $summary && length $summary) {
                        Dragline::Job::Steps::save(
                            $dbh, 'dossier', $dossier_id, $step_name,
                            { summary => $summary }
                        );
                        push @chunk_summaries, $summary;
                    }
                }
                $chunk_idx++;
            }
        }

        my $context = join("\n\n---\n\n", @chunk_summaries);

        # ---- Reduce phase ----
        for my $section (@SECTIONS) {
            # Honour cancellation: exit if dossier status is no longer 'generating'
            my $current_status = $dbh->selectrow_array(
                q{SELECT status FROM dossiers WHERE id = ?}, undef, $dossier_id,
            );
            unless ($current_status && $current_status eq 'generating') {
                $log->info("Synthesise: dossier $dossier_id cancelled, exiting");
                return 1;
            }
            my $step_name = "reduce_section_$section->{number}";
            if (Dragline::Job::Steps::is_done($dbh, 'dossier', $dossier_id, $step_name)
                && !$force_set{ $section->{number} }) {
                next;
            }

            my $sys = "You are an expert intelligence analyst. Generate the '$section->{name}'"
                . " section of a structured intelligence dossier. Use only the provided source"
                . " summaries. Be precise and cite source URLs where available.";

            my ($content, $provider, $tokens) = Dragline::LLM::complete(
                $dbh, $settings_getter,
                task_type     => $section->{task_type},
                system_prompt => $sys,
                user_prompt   => $context,
                max_tokens    => 2048,
                target_id     => $target_id,
            );

            unless (defined $content && length $content) {
                $log->warn("Synthesise: no output for section $section->{number} ($section->{name})");
                $content = '';
            }

            my $sec_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO dossier_sections
                    (id, dossier_id, section_number, section_name, content, model_used, token_count)
                  VALUES (?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT(dossier_id, section_number) DO UPDATE SET
                    content     = excluded.content,
                    model_used  = excluded.model_used,
                    token_count = excluded.token_count,
                    updated_at  = datetime('now')},
                undef,
                $sec_id, $dossier_id, $section->{number}, $section->{name},
                $content, $provider // 'unknown', $tokens // 0,
            );

            Dragline::Job::Steps::mark_done($dbh, 'dossier', $dossier_id, $step_name);
        }

        # ---- Atomic completion: guard, status, version, event ----
        $dbh->begin_work;
        eval {
            my $section_count = $dbh->selectrow_array(
                q{SELECT COUNT(*) FROM dossier_sections WHERE dossier_id = ? AND LENGTH(COALESCE(content,'')) > 0},
                undef, $dossier_id,
            );
            if ($section_count < 10) {
                die "Synthesise: only $section_count/10 sections present for dossier $dossier_id, will retry";
            }

            $dbh->do(
                q{UPDATE dossiers SET status='current', generated_at=datetime('now'),
                  updated_at=datetime('now') WHERE id=?},
                undef, $dossier_id,
            );

            my $sections = $dbh->selectall_arrayref(
                q{SELECT section_number, section_name, content, model_used, token_count
                  FROM dossier_sections WHERE dossier_id = ? ORDER BY section_number},
                { Slice => {} }, $dossier_id,
            );
            my $version_num = $dbh->selectrow_array(
                q{SELECT COALESCE(MAX(version_number), 0) + 1 FROM dossier_versions WHERE dossier_id = ?},
                undef, $dossier_id,
            );
            my $snap_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO dossier_versions
                    (id, dossier_id, target_id, version_number, snapshot_json, created_by)
                  VALUES (?, ?, ?, ?, ?, 'synthesise')},
                undef, $snap_id, $dossier_id, $target_id, $version_num,
                encode_json($sections),
            );

            my $ce_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO change_events
                    (id, target_id, event_type, summary, severity)
                  VALUES (?, ?, 'dossier_updated', 'Dossier updated for target', 'info')},
                undef, $ce_id, $target_id,
            );

            $dbh->commit;

            $self->app->minion->enqueue('forward_assess',
                [{ target_id => $target_id }],
                { priority => 3, attempts => 3 }
            );
            $self->app->minion->enqueue('timeline_extract',
                [{ target_id => $target_id }],
                { priority => 3, attempts => 3 }
            );

            $log->info("Synthesise: dossier $dossier_id complete for target $target_id (version $version_num)");
            1;
        } or do {
            my $err = $@;
            eval { $dbh->rollback; };
            die $err;
        };
    };

    unless ($ok) {
        my $err = $@;
        eval {
            $dbh->do(
                q{UPDATE dossiers SET status='failed', updated_at=datetime('now') WHERE id=?},
                undef, $dossier_id,
            );
        };
        $log->error("Synthesise: failed for target $target_id: $err");
        die $err;
    }
}

sub _split_chunks {
    my ($text, $words_per_chunk) = @_;
    return () unless defined $text && length $text;
    my @words  = split(' ', $text);
    my @chunks;
    while (@words) {
        push @chunks, join(' ', splice(@words, 0, $words_per_chunk));
    }
    return @chunks;
}

1;
