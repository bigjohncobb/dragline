use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

# Set up a project and two targets for the tests
my $t = admin_ua();

my $project_id = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Target Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'Target Test Project'}
    );
    $proj->{id};
};

subtest 'Create target in project' => sub {
    $t->get_ok("/projects/$project_id/targets/new")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/projects/$project_id/targets" => form => {
        canonical_name => 'Acme Corp',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);

    $t->get_ok('/targets')->status_is(200);
    like($t->tx->res->body, qr/Acme Corp/, 'Target appears in list');
};

subtest 'Duplicate canonical_name in same project fails' => sub {
    $t->get_ok("/projects/$project_id/targets/new")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/projects/$project_id/targets" => form => {
        canonical_name => 'Acme Corp',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);

    my ($count) = db()->selectrow_array(
        q{SELECT COUNT(*) FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    is($count, 1, 'Only one target with that name in project');
};

subtest 'Same canonical_name in different project succeeds' => sub {
    # Create second project
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Second Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj2 = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'Second Project'}
    );

    $t->get_ok("/projects/$proj2->{id}/targets/new")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/projects/$proj2->{id}/targets" => form => {
        canonical_name => 'Acme Corp',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);

    my ($count) = db()->selectrow_array(
        q{SELECT COUNT(*) FROM targets WHERE canonical_name = 'Acme Corp'}
    );
    is($count, 2, 'Two targets with same name in different projects');
};

subtest 'Add alias to target' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/aliases" => form => {
        alias       => 'Acme Incorporated',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    like($t->tx->res->body, qr/Acme Incorporated/, 'Alias appears on target page');
};

subtest 'Delete alias' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};
    my $alias = db()->selectrow_hashref(
        q{SELECT id FROM target_aliases WHERE alias = 'Acme Incorporated'}
    );

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/aliases/$alias->{id}/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    unlike($t->tx->res->body, qr/Acme Incorporated/, 'Alias removed');
};

subtest 'Add domain' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/domains" => form => {
        domain      => 'acme.example.com',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    like($t->tx->res->body, qr/acme\.example\.com/, 'Domain appears on target page');
};

subtest 'Delete domain' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};
    my $dom = db()->selectrow_hashref(
        q{SELECT id FROM target_domains WHERE domain = 'acme.example.com'}
    );

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/domains/$dom->{id}/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    unlike($t->tx->res->body, qr/acme\.example\.com/, 'Domain removed');
};

subtest 'Deactivate target' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/deactivate" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    like($t->tx->res->body, qr/inactive/, 'Target shown as inactive');
};

subtest 'Reactivate target' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};

    $t->get_ok("/targets/$tid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/activate" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid")->status_is(200);
    like($t->tx->res->body, qr/active/, 'Target shown as active');
};

subtest 'Update monitoring cadences' => sub {
    my $target = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Acme Corp' AND project_id = ?},
        undef, $project_id,
    );
    my $tid = $target->{id};

    $t->get_ok("/targets/$tid/monitoring")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$tid/monitoring" => form => {
        forge_sync_cadence => 'disabled',
        crawl_cadence      => 'daily',
        discover_cadence   => 'monthly',
        _csrf_token        => $csrf,
    })->status_is(302);

    $t->get_ok("/targets/$tid/monitoring")->status_is(200);
    my $body = $t->tx->res->body;
    like($body, qr/value="disabled" selected/, 'Forge sync set to disabled');
    like($body, qr/value="daily" selected/,    'Crawl set to daily');
    like($body, qr/value="monthly" selected/,  'Discover set to monthly');
};

done_testing();
