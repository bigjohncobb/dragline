use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

# Create a project and target for tests
my $project_id = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Feature Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'Feature Test Project'}
    );
    $proj->{id};
};

my $target_id = do {
    $t->get_ok("/projects/$project_id/targets/new")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/projects/$project_id/targets" => form => {
        canonical_name => 'Feature Target',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);
    my $tgt = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Feature Target'}
    );
    $tgt->{id};
};

subtest 'Bookmarks' => sub {
    $t->get_ok('/bookmarks')->status_is(200);
    like($t->tx->res->body, qr/Bookmarks/, 'Bookmarks page loads');

    my $csrf = extract_csrf($t);
    $t->post_ok('/bookmarks/collections' => form => {
        name        => 'My Collection',
        _csrf_token => $csrf,
    })->status_is(302);

    my $col = db()->selectrow_hashref(
        q{SELECT id FROM bookmark_collections WHERE name = 'My Collection'}
    );
    ok($col, 'Collection created');
    my $col_id = $col->{id};

    $t->get_ok("/bookmarks/collections/$col_id")->status_is(200);
    like($t->tx->res->body, qr/My Collection/, 'Collection page loads');

    $t->get_ok('/bookmarks')->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok('/bookmarks' => form => {
        collection_id => $col_id,
        target_id     => $target_id,
        _csrf_token   => $csrf,
    })->status_is(302);

    my $bm = db()->selectrow_hashref(
        q{SELECT id FROM bookmarks WHERE collection_id = ? AND target_id = ?},
        undef, $col_id, $target_id,
    );
    ok($bm, 'Bookmark created');

    $t->get_ok("/bookmarks/collections/$col_id")->status_is(200);
    like($t->tx->res->body, qr/Feature Target/, 'Bookmark appears on collection page');

    $t->get_ok('/bookmarks')->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/bookmarks/$bm->{id}/delete" => form => {
        collection_id => $col_id,
        _csrf_token   => $csrf,
    })->status_is(302);

    $bm = db()->selectrow_hashref(
        q{SELECT id FROM bookmarks WHERE collection_id = ? AND target_id = ?},
        undef, $col_id, $target_id,
    );
    ok(!$bm, 'Bookmark deleted');

    $t->get_ok('/bookmarks')->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/bookmarks/collections/$col_id/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $col = db()->selectrow_hashref(
        q{SELECT id FROM bookmark_collections WHERE name = 'My Collection'}
    );
    ok(!$col, 'Collection deleted');
};

subtest 'Saved queries' => sub {
    $t->get_ok('/bookmarks')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/saved-queries' => form => {
        name        => 'Test Query',
        query_type  => 'text',
        query_text  => 'test search',
        target_id   => $target_id,
        _csrf_token => $csrf,
    })->status_is(302);

    my $sq = db()->selectrow_hashref(
        q{SELECT id FROM saved_queries WHERE name = 'Test Query'}
    );
    ok($sq, 'Saved query created');

    $t->get_ok('/bookmarks')->status_is(200);
    like($t->tx->res->body, qr/Test Query/, 'Saved query appears on bookmarks page');

    $csrf = extract_csrf($t);
    $t->post_ok("/saved-queries/$sq->{id}/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $sq = db()->selectrow_hashref(
        q{SELECT id FROM saved_queries WHERE name = 'Test Query'}
    );
    ok(!$sq, 'Saved query deleted');
};

subtest 'Webhooks (admin)' => sub {
    $t->get_ok('/admin/webhooks')->status_is(200);
    like($t->tx->res->body, qr/Webhook Management/, 'Webhooks page loads');

    my $csrf = extract_csrf($t);
    $t->post_ok('/admin/webhooks' => form => {
        name        => 'Test Hook',
        url         => 'http://example.com/hook',
        event_types => '["*"]',
        _csrf_token => $csrf,
    })->status_is(302);

    my $hook = db()->selectrow_hashref(
        q{SELECT id FROM webhook_configs WHERE name = 'Test Hook'}
    );
    ok($hook, 'Webhook created');
    my $hook_id = $hook->{id};

    $t->get_ok("/admin/webhooks/$hook_id/deliveries")->status_is(200);
    like($t->tx->res->body, qr/Test Hook/, 'Deliveries page loads');

    $t->get_ok('/admin/webhooks')->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/admin/webhooks/$hook_id/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $hook = db()->selectrow_hashref(
        q{SELECT id FROM webhook_configs WHERE name = 'Test Hook'}
    );
    ok(!$hook, 'Webhook deleted');
};

subtest 'Notifications' => sub {
    $t->get_ok('/notifications')->status_is(200);
    like($t->tx->res->body, qr/Notifications/, 'Notifications page loads');

    $t->get_ok('/notifications/preferences')->status_is(200);
    like($t->tx->res->body, qr/Notification Preferences/, 'Preferences page loads');

    # Test dispatch_notification helper
    my $app = app();
    my $user = db()->selectrow_hashref(q{SELECT id FROM users WHERE username_lower = 'admin'});
    $app->dispatch_notification($user->{id}, 'new_content', 'Test Subject', 'Test body', '/targets/' . $target_id);

    my $notif = db()->selectrow_hashref(
        q{SELECT id FROM user_notifications WHERE subject = 'Test Subject'}
    );
    ok($notif, 'Notification dispatched');

    $t->get_ok('/notifications')->status_is(200);
    like($t->tx->res->body, qr/Test Subject/, 'Notification appears in list');

    my $csrf = extract_csrf($t);
    $t->post_ok("/notifications/$notif->{id}/read" => form => {
        _csrf_token => $csrf,
    })->status_is(200);

    my $updated = db()->selectrow_hashref(
        q{SELECT is_read FROM user_notifications WHERE id = ?},
        undef, $notif->{id},
    );
    is($updated->{is_read}, 1, 'Notification marked read');

    $t->get_ok('/notifications')->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok('/notifications/read-all' => form => {
        _csrf_token => $csrf,
    })->status_is(200);
};

subtest 'API intelligence endpoint' => sub {
    # Create an API key
    my $api_key = 'dl_test_' . time();
    require Digest::SHA;
    my $hash = Digest::SHA::sha256_hex($api_key);
    db()->do(
        q{INSERT INTO api_keys (id, name, key_hash, key_prefix, role, active, created_at, updated_at)
          VALUES (?, ?, ?, ?, 'admin', 1, datetime('now'), datetime('now'))},
        undef, 'test-api-key-1', 'Test Key', $hash, substr($api_key, 0, 8),
    );

    my $api_t = Test::Mojo->new(app());
    $api_t->get_ok("/api/targets/$target_id/intelligence" => { Authorization => "Bearer $api_key" })
        ->status_is(200)
        ->json_has('/target')
        ->json_has('/aliases')
        ->json_has('/domains')
        ->json_has('/people')
        ->json_has('/events')
        ->json_has('/content')
        ->json_has('/dossier')
        ->json_has('/monitoring')
        ->json_has('/forge_items')
        ->json_has('/org_structure')
        ->json_has('/peer_relationships')
        ->json_has('/gap_signals')
        ->json_has('/sanctions_matches');
};

subtest 'Report.txt endpoint' => sub {
    $t->get_ok("/targets/$target_id/report.txt")->status_is(200)
        ->content_type_like(qr{text/plain})
        ->header_like('Content-Disposition' => qr/attachment/);
    like($t->tx->res->body, qr/INTELLIGENCE REPORT/, 'Report contains header');
    like($t->tx->res->body, qr/Feature Target/, 'Report contains target name');
};

done_testing();
