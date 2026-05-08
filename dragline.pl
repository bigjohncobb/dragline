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
use JSON::PP qw(encode_json);
use Scalar::Util qw(looks_like_number);

# In-memory rate-limit state — resets on restart
my %_rate_limit_windows;
my $_uuid_gen = Data::UUID->new;

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
        if ($remote eq '127.0.0.1' || $remote eq '::1') {
            $ip = $c->req->headers->header('X-Forwarded-For') // $remote;
            $ip =~ s/\s*,.*//;  # take first address
            $ip =~ s/^\s+|\s+$//g;
        } else {
            $ip = $remote;
        }

        my $key  = "tier:$tier:$ip";
        my $now  = time();
        my $win  = $cfg->{window};

        $_rate_limit_windows{$key} //= [];
        my $entries = $_rate_limit_windows{$key};

        # Prune entries outside the window
        @$entries = grep { $_ > $now - $win } @$entries;

        # Delete key entirely if no entries remain to prevent unbounded hash growth
        unless (@$entries) {
            delete $_rate_limit_windows{$key};
        }

        # Hard cap on total keys to prevent memory exhaustion under high traffic
        if (keys %_rate_limit_windows > 50000) {
            my @oldest = sort { ($_rate_limit_windows{$a}[0] // 0) <=> ($_rate_limit_windows{$b}[0] // 0) } keys %_rate_limit_windows;
            splice @oldest, int(@oldest / 2);
            delete @_rate_limit_windows{@oldest};
        }

        if (scalar(@$entries) >= $cfg->{max}) {
            return 0;
        }
        push @$entries, $now;
        return 1;
    });

    $self->helper(airgap_mode => sub ($c) {
        return ($ENV{DRAGLINE_AIRGAP} // '0') eq '1' ? 1 : 0;
    });

    $self->helper(dispatch_webhook => sub ($c, $event_type, $payload) {
        eval {
            my $configs = $c->db->selectall_arrayref(
                q{SELECT id FROM webhook_configs WHERE active = 1},
                { Slice => {} },
            );
            for my $cfg (@$configs) {
                $c->minion->enqueue(webhook_deliver => [{
                    webhook_id => $cfg->{id},
                    event_type => $event_type,
                    payload    => $payload,
                }], { attempts => 3 });
            }
        };
        $c->app->log->error("dispatch_webhook failed: $@") if $@;
    });

    $self->helper(dispatch_notification => sub ($c, $user_id, $event_type, $subject, $body, $link_url = undef) {
        eval {
            my $pref = $c->db->selectrow_hashref(
                q{SELECT web_enabled FROM notification_preferences
                  WHERE user_id = ? AND event_type = ?},
                undef, $user_id, $event_type,
            );
            # Default to enabled if no preference set
            my $web_enabled = $pref ? $pref->{web_enabled} : 1;
            return unless $web_enabled;

            my $id = $c->new_uuid;
            $c->db->do(
                q{INSERT INTO user_notifications
                  (id, user_id, event_type, subject, body, link_url, created_at)
                  VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
                undef, $id, $user_id, $event_type, $subject, $body, $link_url,
            );
        };
        $c->app->log->error("dispatch_notification failed: $@") if $@;
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
    $auth->get('/admin/crawl-queue')->to('Content#crawl_queue');
    $auth->post('/admin/crawl-queue/:queue_id/retry')->to('Content#retry_crawl');
    $auth->post('/admin/crawl-queue/:queue_id/delete')->to('Content#delete_crawl_queue');

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
    $auth->post('/bookmarks/collections')->to('Bookmarks#create_collection');
    $auth->post('/bookmarks/collections/:id/delete')->to('Bookmarks#delete_collection');
    $auth->get('/bookmarks/collections/:id')->to('Bookmarks#show_collection');
    $auth->post('/bookmarks')->to('Bookmarks#add_bookmark');
    $auth->post('/bookmarks/:bookmark_id/delete')->to('Bookmarks#delete_bookmark');
    $auth->post('/saved-queries')->to('Bookmarks#create_saved_query');
    $auth->post('/saved-queries/:id/delete')->to('Bookmarks#delete_saved_query');

    $auth->get('/notifications')->to('Notifications#index');
    $auth->post('/notifications/:id/read')->to('Notifications#mark_read');
    $auth->post('/notifications/read-all')->to('Notifications#mark_all_read');
    $auth->get('/notifications/preferences')->to('Notifications#preferences');
    $auth->post('/notifications/preferences')->to('Notifications#update_preferences');

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
    $admin->post('/users/:id/delete')->to('Admin#delete_user');
    $admin->get('/api-keys')->to('Admin#api_keys');
    $admin->post('/api-keys')->to('Admin#create_api_key');
    $admin->post('/api-keys/:id/delete')->to('Admin#delete_api_key');
    $admin->post('/api-keys/:id/rotate')->to('Admin#rotate_api_key');

    $admin->get('/import-targets')->to('Admin#import_targets_form');
    $admin->post('/import-targets')->to('Admin#import_targets');

    $admin->get('/webhooks')->to('Webhooks#index');
    $admin->post('/webhooks')->to('Webhooks#create');
    $admin->post('/webhooks/:id')->to('Webhooks#update');
    $admin->post('/webhooks/:id/delete')->to('Webhooks#delete');
    $admin->get('/webhooks/:id/deliveries')->to('Webhooks#deliveries');

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
