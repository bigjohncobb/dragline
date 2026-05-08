use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

# Create a target for API tests
my $target_id = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'API Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'API Test Project'}
    );

    $t->get_ok("/projects/$proj->{id}/targets/new")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/projects/$proj->{id}/targets" => form => {
        canonical_name => 'API Target',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);
    my $tgt = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'API Target'}
    );
    $tgt->{id};
};

# Create an API key via admin endpoint
my $api_key = do {
    $t->get_ok('/admin/api-keys')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/admin/api-keys' => form => {
        name        => 'test-key',
        role        => 'admin',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok('/admin/api-keys')->status_is(200);
    my $body = $t->tx->res->body;
    $body =~ /id="new-key-value">([a-f0-9]+)<\/code>/
        or die "Could not extract API key from admin page";
    $1;
};

# Insert a change event for change-feed tests
db()->do(
    q{INSERT INTO change_events (id, target_id, event_type, summary, severity, created_at)
      VALUES (?, ?, 'new_content', 'Test change event', 'info', datetime('now'))},
    undef, 'ev-api-001', $target_id,
);

my $api = Test::Mojo->new(app());

subtest 'GET /api/targets without token returns 401' => sub {
    $api->get_ok('/api/targets')->status_is(401)->json_is('/error', 'Unauthorized');
};

subtest 'GET /api/targets with invalid token returns 401' => sub {
    $api->get_ok('/api/targets' => { Authorization => 'Bearer invalidtoken123' })
        ->status_is(401)->json_is('/error', 'Unauthorized');
};

subtest 'GET /api/targets with valid token returns array' => sub {
    $api->get_ok('/api/targets' => { Authorization => "Bearer $api_key" })
        ->status_is(200)
        ->json_has('/0/id');
};

subtest 'GET /api/targets/:id returns correct target' => sub {
    $api->get_ok("/api/targets/$target_id" => { Authorization => "Bearer $api_key" })
        ->status_is(200)
        ->json_is('/canonical_name', 'API Target')
        ->json_is('/entity_type', 'company');
};

subtest 'GET /api/change-feed returns events' => sub {
    $api->get_ok('/api/change-feed' => { Authorization => "Bearer $api_key" })
        ->status_is(200)
        ->json_has('/0/id');
};

subtest 'GET /api/change-feed with since param returns events' => sub {
    $api->get_ok('/api/change-feed?since=2000-01-01T00:00:00Z' => {
        Authorization => "Bearer $api_key"
    })->status_is(200)->json_has('/0/id');
};

subtest 'GET /api/targets/:id/dossier with no current dossier returns 404' => sub {
    $api->get_ok("/api/targets/$target_id/dossier" => {
        Authorization => "Bearer $api_key"
    })->status_is(404)->json_is('/error', 'No current dossier');
};

done_testing();
