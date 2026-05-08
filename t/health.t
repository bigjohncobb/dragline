use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = Test::Mojo->new(app());

subtest 'GET /health returns 200' => sub {
    $t->get_ok('/health')->status_is(200);
};

subtest 'Health response is valid JSON with status ok' => sub {
    $t->get_ok('/health')->status_is(200)->json_is('/status', 'ok');
};

subtest 'No authentication required' => sub {
    # Ensure no session cookie is present by using a fresh UA
    my $ua = Test::Mojo->new(app());
    $ua->get_ok('/health')->status_is(200)->json_is('/status', 'ok');
};

done_testing();
