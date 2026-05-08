use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

# Create a target for role association
my $target_id = do {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'People Test Project',
        _csrf_token => $csrf,
    })->status_is(302);
    my $proj = db()->selectrow_hashref(
        q{SELECT id FROM projects WHERE name = 'People Test Project'}
    );

    $t->get_ok("/projects/$proj->{id}/targets/new")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/projects/$proj->{id}/targets" => form => {
        canonical_name => 'People Target',
        entity_type    => 'company',
        _csrf_token    => $csrf,
    })->status_is(302);
    my $tgt = db()->selectrow_hashref(
        q{SELECT id FROM targets WHERE canonical_name = 'People Target'}
    );
    $tgt->{id};
};

subtest 'POST /people creates person' => sub {
    $t->get_ok('/people/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/people' => form => {
        canonical_name => 'Jane Doe',
        nationality    => 'US',
        _csrf_token    => $csrf,
    })->status_is(302);

    $t->get_ok('/people')->status_is(200);
    like($t->tx->res->body, qr/Jane Doe/, 'Person appears in list');
};

subtest 'Add role to person' => sub {
    my $person = db()->selectrow_hashref(
        q{SELECT id FROM people WHERE canonical_name = 'Jane Doe'}
    );
    my $pid = $person->{id};

    $t->get_ok("/people/$pid")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/people/$pid/roles" => form => {
        target_id   => $target_id,
        title       => 'CEO',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/people/$pid")->status_is(200);
    like($t->tx->res->body, qr/CEO/, 'Role appears on person page');
    like($t->tx->res->body, qr/People Target/, 'Target name shown');
};

subtest 'Add connection between people' => sub {
    # Create second person
    $t->get_ok('/people/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/people' => form => {
        canonical_name => 'John Smith',
        _csrf_token    => $csrf,
    })->status_is(302);

    my $p1 = db()->selectrow_hashref(q{SELECT id FROM people WHERE canonical_name = 'Jane Doe'});
    my $p2 = db()->selectrow_hashref(q{SELECT id FROM people WHERE canonical_name = 'John Smith'});

    $t->get_ok("/people/$p1->{id}")->status_is(200);
    $csrf = extract_csrf($t);
    $t->post_ok("/people/$p1->{id}/connections" => form => {
        other_person_id   => $p2->{id},
        relationship_type => 'shared_board',
        _csrf_token       => $csrf,
    })->status_is(302);

    $t->get_ok("/people/$p1->{id}")->status_is(200);
    like($t->tx->res->body, qr/John Smith/, 'Connection appears');
    like($t->tx->res->body, qr/shared board/i, 'Relationship type shown');
};

subtest 'Duplicate connection rejected' => sub {
    my $p1 = db()->selectrow_hashref(q{SELECT id FROM people WHERE canonical_name = 'Jane Doe'});
    my $p2 = db()->selectrow_hashref(q{SELECT id FROM people WHERE canonical_name = 'John Smith'});

    $t->get_ok("/people/$p1->{id}")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/people/$p1->{id}/connections" => form => {
        other_person_id   => $p2->{id},
        relationship_type => 'shared_board',
        _csrf_token       => $csrf,
    })->status_is(302);

    # Follow redirect to see flash error
    $t->get_ok($t->tx->res->headers->location)->status_is(200);
    like($t->tx->res->body, qr/Connection already exists/i, 'Duplicate connection error');
};

done_testing();
