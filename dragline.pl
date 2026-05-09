#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use lib 'lib', 'local/lib/perl5';

package Dragline;
use Mojo::Base 'Mojolicious', -signatures;

use Dragline::DB;
use Dragline::Crypto;
use Dragline::SSRF;
use Dragline::Cost;
use Data::UUID;
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(encode_json decode_json);
use Scalar::Util qw(looks_like_number);

my $_uuid_gen = Data::UUID->new;

# Trusted reverse-proxy IPs allowed to supply X-Forwarded-For.
# Set DRAGLINE_TRUSTED_PROXIES to a comma-separated list (e.g. "127.0.0.1,10.0.0.1").
# Empty by default — headers from unknown sources are ignored.
my %_trusted_proxies;

sub startup ($self) {

    # ------------------------------------------------------------------ #
    # Environment                                                          #
    # ------------------------------------------------------------------ #

    my $secret = $ENV{DRAGLINE_SECRET}
        or die "FATAL: DRAGLINE_SECRET is required and must be at least 32 characters\n";
    die "FATAL: DRAGLINE_SECRET is required and must be at least 32 characters\n"
        if length($secret) < 32;

    my $db_path        = $ENV{DRAGLINE_DB}        // './dragline.db';
    my $airgap         = $ENV{DRAGLINE_AIRGAP}    // '0';
    my $port           = $ENV{DRAGLINE_PORT}       // 3001;
    my $minion_db_path = $ENV{DRAGLINE_MINION_DB}  // './minion.db';

    %_trusted_proxies = map { $_ => 1 }
        grep { $_ } split /,\s*/, ($ENV{DRAGLINE_TRUSTED_PROXIES} // '');

    # ------------------------------------------------------------------ #
    # Database                                                             #
    # ------------------------------------------------------------------ #

    Dragline::DB::get_dbh($db_path);  # initialise schema on first run

    # ------------------------------------------------------------------ #
    # Minion                                                               #
    # ------------------------------------------------------------------ #

    $self->plugin('Minion', { SQLite => $minion_db_path });

    $self->minion->add_task(crawl_static   => 'Dragline::Job::CrawlStatic');
    $self->minion->add_task(crawl_js       => 'Dragline::Job::CrawlJS');
    $self->minion->add_task(ingest_pdf     => 'Dragline::Job::IngestPDF');
    $self->minion->add_task(forge_sync     => 'Dragline::Job::ForgeSync');
    $self->minion->add_task(discover       => 'Dragline::Job::Discover');
    $self->minion->add_task(embed          => 'Dragline::Job::Embed');
    $self->minion->add_task(synthesise     => 'Dragline::Job::Synthesise');
    $self->minion->add_task(score          => 'Dragline::Job::Score');
    $self->minion->add_task(gap_detect     => 'Dragline::Job::GapDetect');
    $self->minion->add_task(cleanup_events => 'Dragline::Job::CleanupEvents');
    $self->minion->add_task(schedule_crawls => 'Dragline::Job::ScheduleCrawls');
    $self->minion->add_task(forward_assess => 'Dragline::Job::ForwardAssess');
    $self->minion->add_task(monitor => 'Dragline::Job::Monitor');
    $self->minion->add_task(timeline_extract => 'Dragline::Job::TimelineExtract');
    $self->minion->add_task(sanctions_screen => 'Dragline::Job::SanctionsScreen');
    $self->minion->add_task(domain_enrich   => 'Dragline::Job::DomainEnrich');
    $self->minion->add_task(doc_intelligence => 'Dragline::Job::DocIntelligence');
    $self->minion->add_task(ner_extract      => 'Dragline::Job::NerExtract');
    $self->minion->add_task(adversarial_check => 'Dragline::Job::AdversarialCheck');
    $self->minion->add_task(backup => 'Dragline::Job::Backup');
    $self->minion->add_task(webhook_deliver => 'Dragline::Job::WebhookDeliver');

    # ------------------------------------------------------------------ #
    # Helpers                                                              #
    # ------------------------------------------------------------------ #

    $self->helper(db => sub ($c) {
        return $c->stash('_dbh') if $c->stash('_dbh');
        my $dbh = Dragline::DB::get_dbh($db_path);
        $c->stash('_dbh', $dbh);
        return $dbh;
    });

    $self->helper(db_for_job => sub ($c) {
        return Dragline::DB::get_dbh($db_path);
    });

    $self->helper(current_user => sub ($c) {
        return $c->session('user');
    });

    $self->helper(require_login => sub ($c) {
        unless ($c->current_user) {
            $c->flash(error => 'Please log in');
            $c->redirect_to('/login');
            return 0;
        }
        return 1;
    });

    $self->helper(require_admin => sub ($c) {
        my $user = $c->current_user;
        unless ($user && $user->{role} eq 'admin') {
            $c->flash(error => 'Admin access required');
            $c->redirect_to('/');
            return 0;
        }
        return 1;
    });

    $self->helper(require_api_key => sub ($c) {
        my $auth = $c->req->headers->authorization // '';
        unless ($auth =~ /^Bearer\s+(.+)$/i) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            return 0;
        }
        my $token = $1;
        my $hash  = sha256_hex($token);

        my $row = $c->db->selectrow_hashref(
            q{SELECT * FROM api_keys WHERE key_hash = ? AND active = 1},
            undef, $hash,
        );
        unless ($row) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            return 0;
        }

        $c->db->do(
            q{UPDATE api_keys SET last_used_at = datetime('now'),
              request_count = request_count + 1 WHERE id = ?},
            undef, $row->{id},
        );
        $c->stash(api_key_role => $row->{role});
        return 1;
    });

    $self->helper(csrf_token => sub ($c) {
        unless ($c->session('_csrf')) {
            require Crypt::PRNG;
            my $bytes = Crypt::PRNG::random_bytes(32);
            $c->session('_csrf', unpack('H*', $bytes));
        }
        return $c->session('_csrf');
    });

    $self->helper(validate_csrf => sub ($c) {
        my $submitted = $c->param('_csrf_token') // '';
        my $stored    = $c->session('_csrf')     // '';
        return $submitted eq $stored ? 1 : 0;
    });

    $self->helper(log_audit => sub ($c, $action, $entity_type, $entity_id, $changes = undef) {
        my $user    = $c->current_user;
        my $user_id = $user ? $user->{id} : undef;
        my $ip      = $c->tx->remote_address;
        my $ua      = $c->req->headers->user_agent;
        my $id      = $_uuid_gen->create_str;
        my $json    = $changes ? encode_json($changes) : undef;

        eval {
            $c->db->do(
                q{INSERT INTO audit_log (id, user_id, action, entity_type, entity_id,
                  changes, ip_address, user_agent, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))},
                undef, $id, $user_id, $action, $entity_type, $entity_id, $json, $ip, $ua,
            );
        };
        $self->log->error("audit_log insert failed: $@") if $@;
    });

    $self->helper(encrypt_value => sub ($c, $plaintext) {
        return Dragline::Crypto::encrypt($plaintext, $secret);
    });

    $self->helper(decrypt_value => sub ($c, $ciphertext) {
        return Dragline::Crypto::decrypt($ciphertext, $secret);
    });

    $self->helper(get_setting => sub ($c, $key) {
        my $row = $c->db->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key = ?},
            undef, $key,
        );
        return undef unless $row;
        return undef if !defined($row->{value}) || $row->{value} eq '';
        return $row->{is_encrypted} ? $c->decrypt_value($row->{value}) : $row->{value};
    });

    $self->helper(set_setting => sub ($c, $key, $value, $is_encrypted) {
        my $stored = ($is_encrypted && defined $value && $value ne '')
            ? $c->encrypt_value($value)
            : $value;
        $c->db->do(
            q{INSERT INTO settings (key, value, is_encrypted, updated_at)
              VALUES (?, ?, ?, datetime('now'))
              ON CONFLICT(key) DO UPDATE SET value = excluded.value,
              is_encrypted = excluded.is_encrypted, updated_at = datetime('now')},
            undef, $key, $stored, $is_encrypted ? 1 : 0,
        );
    });

    $self->helper(new_uuid => sub ($c) {
        return $_uuid_gen->create_str;
    });

    $self->helper(content_hash => sub ($c, $text) {
        return sha256_hex($text);
    });

    $self->helper(check_ssrf => sub ($c, $url) {
        my ($ok, $reason) = Dragline::SSRF::validate($url);
        return $ok;
    });

    $self->helper(rate_limit => sub ($c, $tier) {
        my %limits = (
            expensive => { max => 5,   window => 60 },
            write     => { max => 30,  window => 60 },
            read      => { max => 120, window => 60 },
        );
        my $cfg = $limits{$tier} or return 1;

        my $remote = $c->tx->remote_address // '';
        my $ip;
        if (%_trusted_proxies && $_trusted_proxies{$remote}) {
            $ip = $c->req->headers->header('X-Forwarded-For') // $remote;
            $ip =~ s/\s*,.*//;
            $ip =~ s/^\s+|\s+$//g;
        } else {
            $ip = $remote;
        }

        my $key  = "tier:$tier:$ip";
        my $now  = time();
        my $win  = $cfg->{window};
        my $dbh  = $c->db;
        my $allowed = 1;

        eval {
            # BEGIN DEFERRED: write lock is only acquired if we actually push a timestamp,
            # avoiding a held exclusive lock during the read-only denied case.
            $dbh->do('BEGIN');
            my ($json) = $dbh->selectrow_array(
                q{SELECT timestamps FROM rate_limit_windows WHERE bucket_key = ?},
                undef, $key,
            );
            my $ts = $json ? decode_json($json) : [];
            @$ts = grep { $_ > $now - $win } @$ts;
            if (scalar(@$ts) >= $cfg->{max}) {
                $allowed = 0;
                $dbh->do('ROLLBACK');
            } else {
                push @$ts, $now;
                $dbh->do(
                    q{INSERT OR REPLACE INTO rate_limit_windows (bucket_key, timestamps, updated_at)
                      VALUES (?, ?, ?)},
                    undef, $key, encode_json($ts), $now,
                );
                $dbh->do('COMMIT');
            }
        };
        if ($@) {
            eval { $dbh->do('ROLLBACK') };
            return 1;  # fail open — don't deny on DB error
        }

        # Periodically remove expired buckets (~1% of requests)
        if (rand() < 0.01) {
            eval { $dbh->do(
                q{DELETE FROM rate_limit_windows WHERE updated_at < ?},
                undef, $now - $win * 2,
            ) };
        }

        return $allowed;
    });

    $self->helper(airgap_mode => sub ($c) {
        return ($ENV{DRAGLINE_AIRGAP} // '0') eq '1' ? 1 : 0;
    });

    $self->helper(fire_webhooks => sub ($c, $target_id, $event_type, $payload_href) {
        eval {
            my $configs = $c->db->selectall_arrayref(
                q{SELECT id, event_types FROM webhook_configs WHERE is_active = 1
                  AND (target_id IS NULL OR target_id = ?)},
                { Slice => {} }, $target_id,
            );
            for my $cfg (@$configs) {
                my $event_types = eval { JSON::PP::decode_json($cfg->{event_types}) } // [];
                my $matches = 0;
                if (@$event_types == 0) {
                    $matches = 1;
                } else {
                    for my $et (@$event_types) {
                        if ($et eq $event_type) {
                            $matches = 1;
                            last;
                        }
                    }
                }
                next unless $matches;
                $c->app->minion->enqueue(
                    webhook_deliver =>
                    [{ config_id => $cfg->{id}, event_type => $event_type,
                       payload   => $payload_href, target_id => $target_id }],
                    { attempts => 4, priority => 1 },
                );
            }
        };
        $c->app->log->error("fire_webhooks failed: $@") if $@;
    });

    $self->helper(notify_users => sub ($c, $target_id, $event_type, $message, $change_event_id = undef) {
        eval {
            my $dbh = $c->db;
            my $users = $dbh->selectall_arrayref(
                q{SELECT u.id FROM users u
                  WHERE u.active = 1
                    AND NOT EXISTS (
                        SELECT 1 FROM notification_preferences np
                        WHERE np.user_id = u.id
                          AND np.event_type = ?
                          AND np.notify_in_app = 0
                    )},
                { Slice => {} }, $event_type,
            );
            for my $user (@$users) {
                $dbh->do(
                    q{INSERT INTO user_notifications
                        (id, user_id, change_event_id, target_id, event_type, message, created_at)
                      VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
                    undef,
                    $c->new_uuid, $user->{id}, $change_event_id,
                    $target_id, $event_type, $message,
                );
            }
        };
        $c->app->log->error("notify_users failed: $@") if $@;
    });

    $self->helper(unread_notification_count => sub ($c) {
        my $user = $c->current_user;
        return 0 unless $user;
        my ($count) = $c->db->selectrow_array(
            q{SELECT COUNT(*) FROM user_notifications WHERE user_id = ? AND is_read = 0},
            undef, $user->{id},
        );
        return $count // 0;
    });

    # ------------------------------------------------------------------ #
    # Sessions                                                             #
    # ------------------------------------------------------------------ #

    $self->secrets([$secret]);
    $self->sessions->cookie_name('dragline_session');
    $self->sessions->samesite('Lax');
    $self->sessions->secure(1);
    # HttpOnly is on by default in Mojolicious

    # ------------------------------------------------------------------ #
    # Hypnotoad                                                            #
    # ------------------------------------------------------------------ #

    $self->max_request_size(50 * 1024 * 1024);

    $self->config(
        hypnotoad => {
            listen => ["http://*:$port"],
        }
    );

    # ------------------------------------------------------------------ #
    # Routes                                                               #
    # ------------------------------------------------------------------ #

    my $r = $self->routes;

    # No-auth routes
    $r->get('/health')->to('Dashboard#health_check');
    $r->get('/login')->to('Auth#login_form');
    $r->post('/login')->to('Auth#login');
    $r->get('/logout')->to('Auth#logout');

    # Password change (any logged-in user)
    my $password_change = $r->under('/change-password')->to(cb => sub ($c) { $c->require_login });
    $password_change->get('')->to('Auth#change_password_form');
    $password_change->post('')->to('Auth#change_password');

    # Protected routes
    my $auth = $r->under('/')->to(cb => sub ($c) { $c->require_login });

    $auth->get('/')->to('Dashboard#index');
    $auth->post('/changes/:id/seen')->to('Dashboard#mark_seen');
    $auth->post('/changes/seen-all')->to('Dashboard#mark_all_seen');

    $auth->get('/projects')->to('Projects#index');
    $auth->get('/projects/new')->to('Projects#new_form');
    $auth->post('/projects')->to('Projects#create');
    $auth->get('/projects/:id')->to('Projects#show');
    $auth->get('/projects/:id/edit')->to('Projects#edit_form');
    $auth->post('/projects/:id')->to('Projects#update');
    $auth->post('/projects/:id/delete')->to('Projects#delete');

    $auth->get('/targets')->to('Targets#index');
    $auth->get('/targets/export')->to('Targets#export_csv');
    $auth->get('/projects/:project_id/targets/new')->to('Targets#new_form');
    $auth->post('/projects/:project_id/targets')->to('Targets#create');
    $auth->get('/targets/:id')->to('Targets#show');
    $auth->get('/targets/:id/edit')->to('Targets#edit_form');
    $auth->post('/targets/:id')->to('Targets#update');
    $auth->post('/targets/:id/delete')->to('Targets#delete');
    $auth->post('/targets/:id/activate')->to('Targets#activate');
    $auth->post('/targets/:id/deactivate')->to('Targets#deactivate');
    $auth->post('/targets/:id/aliases')->to('Targets#add_alias');
    $auth->post('/targets/:id/aliases/:alias_id/delete')->to('Targets#delete_alias');
    $auth->post('/targets/:id/domains')->to('Targets#add_domain');
    $auth->post('/targets/:id/domains/:domain_id/delete')->to('Targets#delete_domain');
    $auth->post('/targets/:id/enrich-domains')->to('Targets#enrich_domains');
    $auth->post('/targets/:id/org-structure')->to('Targets#add_org_structure');
    $auth->post('/targets/:id/org-structure/:rel_id/delete')->to('Targets#delete_org_structure');
    $auth->post('/targets/:id/peers')->to('Targets#add_peer');
    $auth->post('/targets/:id/peers/:rel_id/delete')->to('Targets#delete_peer');
    $auth->get('/targets/:id/monitoring')->to('Targets#monitoring_form');
    $auth->post('/targets/:id/monitoring')->to('Targets#update_monitoring');

    $auth->get('/targets/:id/content')->to('Content#index');
    $auth->post('/targets/:id/content/crawl')->to('Content#queue_crawl');
    $auth->post('/targets/:id/content/upload')->to('Content#upload');
    $auth->post('/targets/:id/content/discover')->to('Content#queue_discover');
    $auth->post('/targets/:id/content/forge-sync')->to('Content#queue_forge_sync');
    $auth->post('/targets/bulk')->to('Targets#bulk_action');
    $auth->get('/targets/:id/content/:content_id/edit')->to('Content#edit_form');
    $auth->post('/targets/:id/content/:content_id')->to('Content#update');
    $auth->post('/targets/:id/content/:content_id/delete')->to('Content#delete');
    $auth->post('/targets/:id/content/:content_id/reprocess')->to('Content#reprocess');
    $auth->post('/targets/:id/content/:content_id/extract')->to('Content#extract_intelligence');
    $auth->get('/targets/:id/watched-sources')->to('Content#watched_sources');
    $auth->post('/targets/:id/watched-sources')->to('Content#add_watched_source');
    $auth->post('/targets/:id/watched-sources/:ws_id/delete')->to('Content#delete_watched_source');

    $auth->get('/targets/:id/dossier')->to('Dossiers#show');
    $auth->post('/targets/:id/dossier/generate')->to('Dossiers#generate');

    $auth->get('/people')->to('People#index');
    $auth->get('/people/new')->to('People#new_form');
    $auth->post('/people')->to('People#create');
    $auth->get('/search')->to('Search#semantic');
    $auth->get('/search/text')->to('Search#text');
    $auth->get('/people/:id')->to('People#show');
    $auth->get('/people/:id/edit')->to('People#edit_form');
    $auth->post('/people/:id')->to('People#update');
    $auth->post('/people/:id/delete')->to('People#delete');
    $auth->post('/people/:id/merge')->to('People#merge');
    $auth->post('/people/:id/roles')->to('People#add_role');
    $auth->post('/people/:id/roles/:role_id/delete')->to('People#delete_role');
    $auth->post('/people/:id/connections')->to('People#add_connection');
    $auth->post('/people/:id/connections/:conn_id/delete')->to('People#delete_connection');

    $auth->get('/bookmarks')->to('Bookmarks#index');
    $auth->post('/bookmarks')->to('Bookmarks#create');
    $auth->post('/bookmarks/:id/delete')->to('Bookmarks#delete');
    $auth->post('/bookmarks/collections')->to('Bookmarks#create_collection');
    $auth->post('/bookmarks/collections/:coll_id/items')->to('Bookmarks#add_to_collection');
    $auth->get('/saved-queries')->to('Bookmarks#saved_queries');
    $auth->post('/saved-queries')->to('Bookmarks#save_query');
    $auth->post('/saved-queries/:id/delete')->to('Bookmarks#delete_query');

    $auth->get('/notifications')->to('Notifications#index');
    $auth->post('/notifications/:id/read')->to('Notifications#mark_read');
    $auth->post('/notifications/read-all')->to('Notifications#mark_all_read');
    $auth->get('/notifications/preferences')->to('Notifications#preferences_form');
    $auth->post('/notifications/preferences')->to('Notifications#update_preferences');

    $auth->get('/settings/webhooks')->to('Settings#webhooks');
    $auth->post('/settings/webhooks')->to('Settings#create_webhook');
    $auth->post('/settings/webhooks/:id/delete')->to('Settings#delete_webhook');

    $auth->get('/targets/:id/report.txt')->to('Targets#report_txt');

    # Admin routes
    my $admin = $r->under('/admin')->to(cb => sub ($c) {
        return 0 unless $c->require_login;
        return 0 unless $c->require_admin;
        return 1;
    });

    $admin->get('/health')->to('Admin#health');
    $admin->get('/settings')->to('Admin#settings_form');
    $admin->post('/settings')->to('Admin#update_settings');
    $admin->get('/costs')->to('Admin#costs');
    $admin->get('/audit')->to('Admin#audit_log');
    $admin->get('/users')->to('Admin#users');
    $admin->post('/users')->to('Admin#create_user');
    $admin->get('/users/:id/edit')->to('Admin#edit_user_form');
    $admin->post('/users/:id')->to('Admin#update_user');
    $admin->post('/users/:id/delete')->to('Admin#delete_user');
    $admin->get('/api-keys')->to('Admin#api_keys');
    $admin->post('/api-keys')->to('Admin#create_api_key');
    $admin->post('/api-keys/:id/delete')->to('Admin#delete_api_key');
    $admin->post('/api-keys/:id/rotate')->to('Admin#rotate_api_key');

    $admin->get('/import-targets')->to('Admin#import_targets_form');
    $admin->post('/import-targets')->to('Admin#import_targets');

    $admin->get('/domain-blocklist')->to('Admin#domain_blocklist');
    $admin->post('/domain-blocklist')->to('Admin#add_domain_blocklist');
    $admin->post('/domain-blocklist/:id/delete')->to('Admin#delete_domain_blocklist');

    $admin->get('/crawl-queue')->to('Content#crawl_queue');
    $admin->post('/crawl-queue/:queue_id/retry')->to('Content#retry_crawl');
    $admin->post('/crawl-queue/:queue_id/delete')->to('Content#delete_crawl_queue');

    $self->plugin('Minion::Admin', { route => $admin->any('/jobs') });

    # Bootstrap the hourly scheduler on startup if no job is queued/running
    eval {
        if ($self->minion->lock('schedule_crawls_bootstrap', 60)) {
            my $r = $self->minion->backend->list_jobs(0, 1, {
                tasks  => ['schedule_crawls'],
                states => ['inactive', 'active'],
            });
            unless ($r && $r->{total}) {
                $self->minion->enqueue('schedule_crawls', [{}], {attempts => 1});
                $self->log->info('ScheduleCrawls: bootstrapped initial recurring job');
            }
            $self->minion->unlock('schedule_crawls_bootstrap');
        }
    };

    # API routes
    my $api = $r->under('/api')->to(cb => sub ($c) { $c->require_api_key });

    $api->get('/targets')->to('Api#targets');
    $api->get('/targets/:id')->to('Api#target');
    $api->get('/targets/:id/content')->to('Api#content');
    $api->get('/targets/:id/dossier')->to('Api#dossier');
    $api->get('/change-feed')->to('Api#change_feed');
    $api->post('/targets/:id/content/upload')->to('Api#upload_content');
    $api->post('/targets')->to('Api#create_target');
    $api->post('/people')->to('Api#create_person');
    $api->get('/targets/:id/intelligence')->to('Api#intelligence');

    # Security headers on every response
    $self->hook(after_dispatch => sub ($c) {
        my $h = $c->res->headers;
        $h->header('X-Frame-Options'        => 'DENY');
        $h->header('X-Content-Type-Options' => 'nosniff');
        $h->header('Referrer-Policy'        => 'strict-origin-when-cross-origin');
        $h->header('Content-Security-Policy' =>
            "default-src 'self'; " .
            "script-src 'self' 'unsafe-inline'; " .
            "style-src 'self' 'unsafe-inline'; " .
            "img-src 'self' data:; " .
            "font-src 'self'; " .
            "connect-src 'self'; " .
            "frame-ancestors 'none'"
        );
    });

    # Custom error pages
    $self->hook(before_render => sub ($c, $args) {
        my $template = $args->{template} // '';
        return unless $args->{status};
        if ($args->{status} == 404) {
            $args->{template} = 'errors/404';
        } elsif ($args->{status} == 500) {
            $args->{template} = 'errors/500';
        }
    });
}

package main;
use Mojolicious::Commands;
Mojolicious::Commands->start_app('Dragline');
