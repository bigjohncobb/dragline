use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

# Create a project and target for content tests
my ($project_id, $target_id) = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Content Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'Content Test Project'}
    );

    $t->get_ok("/projects/$proj->{id}/targets/new")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/projects/$proj->{id}/targets" => form => {
        canonical_name => 'Content Target',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);
    my $tgt = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'Content Target'}
    );
    ($proj->{id}, $tgt->{id});
};

subtest 'Crawl valid URL queues job and crawl_queue entry' => sub {
    my $url = 'http://example.com/page';

    $t->get_ok("/targets/$target_id/content")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$target_id/content/crawl" => form => {
        url         => $url,
        _csrf_token => $csrf,
    })->status_is(302);

    my $queued = db()->selectrow_array(
        q{SELECT COUNT(*) FROM crawl_queue WHERE target_id = ? AND url = ?},
        undef, $target_id, $url,
    );
    is($queued, 1, 'URL appears in crawl_queue');

    my $jobs = app()->minion->backend->list_jobs(0, 10, { tasks => ['crawl_static'] });
    ok($jobs->{total} >= 1, 'Minion crawl_static job enqueued');
};

subtest 'Crawl private IP URL blocked by SSRF' => sub {
    my $url = 'http://192.168.1.1/secret';

    # Clear any existing crawl_queue entries for this URL
    db()->do(q{DELETE FROM crawl_queue WHERE target_id = ? AND url = ?},
        undef, $target_id, $url);

    $t->get_ok("/targets/$target_id/content")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$target_id/content/crawl" => form => {
        url         => $url,
        _csrf_token => $csrf,
    })->status_is(302);

    my $queued = db()->selectrow_array(
        q{SELECT COUNT(*) FROM crawl_queue WHERE target_id = ? AND url = ?},
        undef, $target_id, $url,
    );
    is($queued, 0, 'Private IP URL not queued');
};

subtest 'Upload valid PDF enqueues job' => sub {
    # Minimal valid PDF header
    my $pdf = "%PDF-1.4\n1 0 obj\n\u003c\u003c\n/Type /Catalog\n\u003e\u003e\nendobj\n";

    $t->get_ok("/targets/$target_id/content")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$target_id/content/upload" => form => {
        _csrf_token => $csrf,
        file        => { content => $pdf, filename => 'test.pdf' },
    })->status_is(302);

    my $jobs = app()->minion->backend->list_jobs(0, 10, { tasks => ['ingest_pdf'] });
    ok($jobs->{total} >= 1, 'Minion ingest_pdf job enqueued');
};

subtest 'Upload PNG renamed to PDF rejected by magic bytes' => sub {
    # PNG magic bytes
    my $png = "\x89PNG\r\n\x1a\n";

    $t->get_ok("/targets/$target_id/content")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/targets/$target_id/content/upload" => form => {
        _csrf_token => $csrf,
        file        => { content => $png, filename => 'fake.pdf' },
    })->status_is(302);

    # Follow redirect to see flash error
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    like($t->tx->res->body, qr/Unsupported file type/i, 'Magic byte rejection flash shown');
};

subtest 'Crawl same URL twice flashes already queued' => sub {
    my $url = 'http://example.com/duplicate';

    # Ensure no existing entry
    db()->do(q{DELETE FROM crawl_queue WHERE target_id = ? AND url = ?},
        undef, $target_id, $url);

    $t->get_ok("/targets/$target_id/content")->status_is(200);
    my $csrf = extract_csrf($t);

    # First queue
    $t->post_ok("/targets/$target_id/content/crawl" => form => {
        url         => $url,
        _csrf_token => $csrf,
    })->status_is(302);

    # Second queue
    $t->get_ok("/targets/$target_id/content")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/targets/$target_id/content/crawl" => form => {
        url         => $url,
        _csrf_token => $csrf,
    })->status_is(302);

    # Follow redirect to see flash
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    like($t->tx->res->body, qr/already queued/i, 'Duplicate queue flash shown');
};

done_testing();
