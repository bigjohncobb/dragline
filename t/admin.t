use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

# Create a project for import tests
my $project_id = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Import Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'Import Test Project'}
    );
    $proj->{id};
};

subtest 'GET /admin/import-targets renders form' => sub {
    $t->get_ok('/admin/import-targets')->status_is(200);
    like($t->tx->res->body, qr/Import Targets/i, 'Page title shown');
};

subtest 'POST /admin/import-targets imports CSV' => sub {
    my $csv = "canonical_name,entity_type,country,project_id,aliases,domains\n"
            . "Gamma Inc,company,US,$project_id,\"Gamma Incorporated\",gamma.example.com\n"
            . "Delta LLC,company,CA,$project_id,,\n";

    $t->get_ok('/admin/import-targets')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/admin/import-targets' => form => {
        _csrf_token => $csrf,
        file        => { content => $csv, filename => 'targets.csv' },
    })->status_is(302);

    $t->get_ok('/targets')->status_is(200);
    like($t->tx->res->body, qr/Gamma Inc/, 'Gamma Inc appears in targets list');
    like($t->tx->res->body, qr/Delta LLC/, 'Delta LLC appears in targets list');

    my $gamma = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Gamma Inc' AND project_id = ?},
        undef, $project_id,
    );
    ok($gamma, 'Gamma Inc created');

    my $alias = db()->selectrow_hashref(
        q{SELECT id FROM target_aliases WHERE target_id = ? AND alias = 'Gamma Incorporated'},
        undef, $gamma->{id},
    );
    ok($alias, 'Alias created for Gamma Inc');

    my $domain = db()->selectrow_hashref(
        q{SELECT id FROM target_domains WHERE target_id = ? AND domain = 'gamma.example.com'},
        undef, $gamma->{id},
    );
    ok($domain, 'Domain created for Gamma Inc');
};

done_testing();
