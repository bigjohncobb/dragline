use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = admin_ua();

subtest 'POST /projects with valid name' => sub {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => 'Alpha Project',
        description => 'Test description',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok('/projects')->status_is(200);
    like($t->tx->res->body, qr/Alpha Project/, 'Project appears in list');
};

subtest 'POST /projects with empty name fails' => sub {
    $t->get_ok('/projects/new')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/projects' => form => {
        name        => '   ',
        _csrf_token => $csrf,
    })->status_is(302);

    # Count should not have increased
    my ($count) = db()->selectrow_array(q{SELECT COUNT(*) FROM projects WHERE name = '   '});
    is($count, 0, 'No project with empty name created');
};

subtest 'Update project' => sub {
    # Get first project id
    my $project = db()->selectrow_hashref(
        q{SELECT * FROM projects WHERE name = 'Alpha Project'}
    );
    ok($project, 'Found project');

    $t->get_ok("/projects/$project->{id}/edit")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/projects/$project->{id}" => form => {
        name        => 'Alpha Project Updated',
        _csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok("/projects/$project->{id}")->status_is(200);
    like($t->tx->res->body, qr/Alpha Project Updated/, 'Updated name shown');
};

subtest 'Delete project with no targets' => sub {
    my $project = db()->selectrow_hashref(
        q{SELECT * FROM projects WHERE name = 'Alpha Project Updated'}
    );
    ok($project, 'Found project to delete');

    $t->get_ok("/projects/$project->{id}/edit")->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok("/projects/$project->{id}/delete" => form => {
        _csrf_token => $csrf,
    })->status_is(302);

    my $gone = db()->selectrow_hashref(
        q{SELECT * FROM projects WHERE id = ?}, undef, $project->{id}
    );
    ok(!$gone, 'Project deleted');
};

subtest 'GET /projects returns correct count' => sub {
    # Create two projects
    for my $name ('Project One', 'Project Two') {
        $t->get_ok('/projects/new')->status_is(200);
        my $csrf = extract_csrf($t);
        $t->post_ok('/projects' => form => {
            name        => $name,
            _csrf_token => $csrf,
        })->status_is(302);
    }

    $t->get_ok('/projects')->status_is(200);
    my $body = $t->tx->res->body;
    like($body, qr/Project One/, 'First project listed');
    like($body, qr/Project Two/, 'Second project listed');

    my ($count) = db()->selectrow_array(q{SELECT COUNT(*) FROM projects});
    is($count, 2, 'Correct count in DB');
};

done_testing();
