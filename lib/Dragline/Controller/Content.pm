package Dragline::Controller::Content;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Encode qw(decode);
use Dragline::Storage;

sub index ($c) {
    my $id   = $c->param('id');
    my $page = $c->param('page') // 1;
    $page = 1 unless $page =~ /^\d+$/ && $page > 0;

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    # Filters
    my $source_type = $c->param('source_type') // '';
    my $date_from   = $c->param('date_from')   // '';
    my $date_to     = $c->param('date_to')     // '';
    my $min_tier    = $c->param('min_tier')    // '';

    my @where = ('target_id = ?');
    my @bind  = ($id);

    if ($source_type && grep { $_ eq $source_type } qw(forge crawl_static bucket_js pdf upload)) {
        push @where, 'source_type = ?';
        push @bind, $source_type;
    }
    if ($date_from =~ /^\d{4}-\d{2}-\d{2}$/) {
        push @where, "created_at >= ?";
        push @bind, "$date_from 00:00:00";
    }
    if ($date_to =~ /^\d{4}-\d{2}-\d{2}$/) {
        push @where, "created_at <= ?";
        push @bind, "$date_to 23:59:59";
    }
    if ($min_tier =~ /^\d+$/ && $min_tier >= 1) {
        push @where, "significance_tier >= ?";
        push @bind, $min_tier;
    }

    my $where_sql = 'WHERE ' . join(' AND ', @where);
    my $limit  = 20;
    my $offset = ($page - 1) * $limit;

    my $content = $c->db->selectall_arrayref(
        qq{SELECT * FROM raw_content $where_sql
          ORDER BY created_at DESC LIMIT ? OFFSET ?},
        { Slice => {} }, @bind, $limit, $offset,
    );

    my ($total) = $c->db->selectrow_array(
        qq{SELECT COUNT(*) FROM raw_content $where_sql}, undef, @bind,
    );

    $c->stash(
        target      => $target,
        content     => $content,
        page        => $page,
        total       => $total,
        per_page    => $limit,
        source_type => $source_type,
        date_from   => $date_from,
        date_to     => $date_to,
        min_tier    => $min_tier,
    );
    $c->render(template => 'targets/content');
}

sub queue_crawl ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id  = $c->param('id');
    my $url = $c->param('url') // '';
    $url =~ s/^\s+|\s+$//g;

    unless (length($url) && $url =~ m{^https?://}i) {
        $c->flash(error => 'Please enter a valid URL starting with http:// or https://');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    unless ($c->check_ssrf($url)) {
        $c->flash(error => 'That URL is not allowed (blocked by security policy).');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $existing = $c->db->selectrow_hashref(
        q{SELECT id FROM crawl_queue
          WHERE target_id = ? AND url = ? AND status IN ('pending','processing')},
        undef, $id, $url,
    );
    if ($existing) {
        $c->flash(error => 'URL already queued for crawling.');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $queue_id = $c->new_uuid;
    $c->db->do(
        q{INSERT OR IGNORE INTO crawl_queue (id, target_id, url, source, status, queued_at)
          VALUES (?, ?, ?, 'manual', 'pending', datetime('now'))},
        undef, $queue_id, $id, $url,
    );

    my $job_id = $c->minion->enqueue(crawl_static => [{ target_id => $id, url => $url }]);
    my $pending = $c->session('pending_jobs') // [];
    push @$pending, { id => "$job_id", task => 'crawl_static', label => "Crawl: $url" };
    splice(@$pending, 0, scalar(@$pending) - 15) if @$pending > 15;
    $c->session(pending_jobs => $pending);

    $c->flash(success => 'URL queued for crawling.');
    $c->redirect_to("/targets/$id/content");
}

sub upload ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $upload = $c->req->upload('file');
    unless ($upload && $upload->size > 0) {
        $c->flash(error => 'Please select a file to upload.');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $max_bytes = 50 * 1024 * 1024;  # 50 MB
    if ($upload->size > $max_bytes) {
        $c->flash(error => 'File too large. Maximum upload size is 50 MB.');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $header = $upload->slurp;
    my $magic  = substr($header, 0, 8);

    if ($magic =~ /^%PDF-/) {
        my $tmp_path = "/tmp/dragline_upload_" . $c->new_uuid . ".pdf";
        $upload->move_to($tmp_path);
        my $filename = $upload->filename || 'upload.pdf';
        my $job_id = $c->minion->enqueue(ingest_pdf => [{ target_id => $id, file_path => $tmp_path, filename => $filename }]);
        $c->flash(success => "PDF queued for ingestion (job $job_id).");
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $text = eval { decode('UTF-8', $header, Encode::FB_CROAK) };
    if ($@) {
        $c->flash(error => 'Unsupported file type. Please upload a PDF or UTF-8 text file.');
        $c->redirect_to("/targets/$id/content");
        return;
    }

    my $hash          = $c->content_hash($text);
    my $content_id    = $c->new_uuid;
    my $word_count    = scalar(split /\s+/, $text);

    eval {
        $c->db->do(
            q{INSERT INTO raw_content
                (id, target_id, source_type, content_text, content_hash, word_count, created_at)
              VALUES (?, ?, 'upload', ?, ?, ?, datetime('now'))},
            undef, $content_id, $id, $text, $hash, $word_count,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'This content has already been uploaded.');
        } else {
            $c->flash(error => 'Failed to save uploaded content.');
        }
        $c->redirect_to("/targets/$id/content");
        return;
    }

    # Dual-write to object storage if configured (non-fatal on failure)
    my $storage_settings = Dragline::Storage::build_settings(sub { $c->get_setting($_[0]) });
    if ($storage_settings) {
        my $s3_key = "content/$id/$content_id.txt";
        my ($ok, $err) = Dragline::Storage::upload_bytes(
            $storage_settings, $s3_key,
            Encode::encode('UTF-8', $text),
            'text/plain; charset=utf-8',
        );
        if ($ok) {
            eval {
                $c->db->do(
                    q{UPDATE raw_content SET storage_key=? WHERE id=?},
                    undef, $s3_key, $content_id,
                );
            };
        } else {
            $c->app->log->warn("Storage upload failed for $content_id: $err");
        }
    }

    $c->flash(success => 'Content uploaded successfully.');
    $c->redirect_to("/targets/$id/content");
}

sub queue_discover ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $job_id = $c->minion->enqueue(discover => [{ target_id => $id }]);
    my $pending = $c->session('pending_jobs') // [];
    push @$pending, { id => "$job_id", task => 'discover', label => 'Discovery' };
    splice(@$pending, 0, scalar(@$pending) - 15) if @$pending > 15;
    $c->session(pending_jobs => $pending);
    $c->flash(success => 'Discovery job queued.');
    $c->redirect_to("/targets/$id/content");
}

sub queue_forge_sync ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $job_id = $c->minion->enqueue(forge_sync => [{ target_id => $id }]);
    my $pending = $c->session('pending_jobs') // [];
    push @$pending, { id => "$job_id", task => 'forge_sync', label => 'Forge sync' };
    splice(@$pending, 0, scalar(@$pending) - 15) if @$pending > 15;
    $c->session(pending_jobs => $pending);
    $c->flash(success => 'Forge sync queued.');
    $c->redirect_to("/targets/$id/content");
}

sub edit_form ($c) {
    my $id = $c->param('id');
    my $content_id = $c->param('content_id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $content = $c->db->selectrow_hashref(
        q{SELECT * FROM raw_content WHERE id = ? AND target_id = ?}, undef, $content_id, $id,
    );
    unless ($content) {
        $c->reply->not_found;
        return;
    }

    $c->stash(target => $target, content => $content);
    $c->render(template => 'targets/content_edit');
}

sub update ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $content_id = $c->param('content_id');
    my $text = $c->param('content_text') // '';

    my $content = $c->db->selectrow_hashref(
        q{SELECT * FROM raw_content WHERE id = ? AND target_id = ?}, undef, $content_id, $id,
    );
    unless ($content) {
        $c->reply->not_found;
        return;
    }

    my $hash = $c->content_hash($text);
    my $word_count = scalar(split /\s+/, $text);

    $c->db->do(
        q{UPDATE raw_content SET
            content_text = ?, content_hash = ?, word_count = ?, updated_at = datetime('now')
          WHERE id = ?},
        undef, $text, $hash, $word_count, $content_id,
    );

    $c->log_audit('update_content', 'raw_content', $content_id, { word_count => $word_count });
    $c->flash(success => 'Content updated.');
    $c->redirect_to("/targets/$id/content");
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $content_id = $c->param('content_id');

    my $content = $c->db->selectrow_hashref(
        q{SELECT * FROM raw_content WHERE id = ? AND target_id = ?}, undef, $content_id, $id,
    );
    unless ($content) {
        $c->reply->not_found;
        return;
    }

    $c->db->do(q{DELETE FROM raw_content WHERE id = ?}, undef, $content_id);
    $c->log_audit('delete_content', 'raw_content', $content_id);
    $c->flash(success => 'Content deleted.');
    $c->redirect_to("/targets/$id/content");
}

sub reprocess ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $content_id = $c->param('content_id');

    my $content = $c->db->selectrow_hashref(
        q{SELECT * FROM raw_content WHERE id = ? AND target_id = ?}, undef, $content_id, $id,
    );
    unless ($content) {
        $c->reply->not_found;
        return;
    }

    # Remove old embedding so it will be regenerated
    $c->db->do(q{DELETE FROM raw_content_embeddings WHERE raw_content_id = ?}, undef, $content_id);

    $c->minion->enqueue(embed => [{ raw_content_id => $content_id }], { attempts => 3 });
    $c->log_audit('reprocess_content', 'raw_content', $content_id);
    $c->flash(success => 'Content queued for reprocessing.');
    $c->redirect_to("/targets/$id/content");
}

sub extract_intelligence ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/content');
    }

    my $id = $c->param('id');
    my $content_id = $c->param('content_id');

    my $content = $c->db->selectrow_hashref(
        q{SELECT * FROM raw_content WHERE id = ? AND target_id = ?}, undef, $content_id, $id,
    );
    unless ($content) {
        $c->reply->not_found;
        return;
    }

    $c->minion->enqueue(doc_intelligence => [{ raw_content_id => $content_id }]);
    $c->log_audit('extract_intelligence', 'raw_content', $content_id);
    $c->flash(success => 'Document intelligence extraction queued.');
    $c->redirect_to("/targets/$id/content");
}

sub crawl_queue ($c) {
    my $status = $c->param('status') // '';
    my @where;
    my @bind;

    if ($status && grep { $_ eq $status } qw(pending processing complete failed skipped)) {
        push @where, 'cq.status = ?';
        push @bind, $status;
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $items = $c->db->selectall_arrayref(
        qq{SELECT cq.*, t.canonical_name AS target_name
          FROM crawl_queue cq
          JOIN targets t ON t.id = cq.target_id
          $where_sql
          ORDER BY cq.queued_at DESC
          LIMIT 200},
        { Slice => {} }, @bind,
    );

    my $counts = $c->db->selectall_arrayref(
        q{SELECT status, COUNT(*) as count FROM crawl_queue GROUP BY status},
        { Slice => {} },
    );

    $c->stash(
        items    => $items,
        counts   => $counts,
        filter   => $status,
    );
    $c->render(template => 'admin/crawl_queue');
}

sub retry_crawl ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $queue_id = $c->param('queue_id');
    my $item = $c->db->selectrow_hashref(
        q{SELECT * FROM crawl_queue WHERE id = ?}, undef, $queue_id,
    );

    unless ($item) {
        $c->flash(error => 'Queue item not found.');
        $c->redirect_to('/admin/crawl-queue');
        return;
    }

    $c->db->do(
        q{UPDATE crawl_queue SET status = 'pending', attempts = 0, last_error = NULL WHERE id = ?},
        undef, $queue_id,
    );

    $c->minion->enqueue(crawl_static => [{
        target_id      => $item->{target_id},
        url            => $item->{url},
        crawl_queue_id => $queue_id,
    }], { attempts => 3 });

    $c->flash(success => 'Crawl job requeued.');
    $c->redirect_to('/admin/crawl-queue');
}

sub delete_crawl_queue ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $queue_id = $c->param('queue_id');
    $c->db->do(q{DELETE FROM crawl_queue WHERE id = ?}, undef, $queue_id);
    $c->flash(success => 'Queue item deleted.');
    $c->redirect_to('/admin/crawl-queue');
}

sub watched_sources ($c) {
    my $id = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }
    my $sources = $c->db->selectall_arrayref(
        q{SELECT * FROM watched_sources WHERE target_id = ? ORDER BY created_at DESC},
        { Slice => {} }, $id,
    );
    $c->stash(target => $target, sources => $sources);
    $c->render(template => 'targets/watched_sources');
}

sub add_watched_source ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }
    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/watched-sources');
    }

    my $id = $c->param('id');
    my $url = $c->param('url') // '';
    my $cadence = $c->param('watch_cadence') // 'daily';
    $url =~ s/^\s+|\s+$//g;

    unless (length($url) && $url =~ m{^https?://}i) {
        $c->flash(error => 'Please enter a valid URL starting with http:// or https://');
        $c->redirect_to("/targets/$id/watched-sources");
        return;
    }
    unless ($c->check_ssrf($url)) {
        $c->flash(error => 'That URL is not allowed (blocked by security policy).');
        $c->redirect_to("/targets/$id/watched-sources");
        return;
    }
    unless (grep { $_ eq $cadence } qw(hourly daily weekly)) {
        $cadence = 'daily';
    }

    my %cadence_offset = (
        hourly  => '+1 hour',
        daily   => '+1 day',
        weekly  => '+7 days',
    );
    my $next_offset = $cadence_offset{$cadence} // '+1 day';

    my $ws_id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO watched_sources
                (id, target_id, url, watch_cadence, next_check_at, created_at, updated_at)
              VALUES (?, ?, ?, ?, datetime('now', ?), datetime('now'), datetime('now'))},
            undef, $ws_id, $id, $url, $cadence, $next_offset,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'This URL is already being watched.');
        } else {
            $c->flash(error => 'Failed to add watched source.');
        }
    } else {
        $c->log_audit('add_watched_source', 'watched_source', $ws_id, { url => $url, cadence => $cadence });
        $c->flash(success => 'Watched source added.');
    }
    $c->redirect_to("/targets/$id/watched-sources");
}

sub delete_watched_source ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }
    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/watched-sources');
    }

    my $id = $c->param('id');
    my $ws_id = $c->param('ws_id');
    $c->db->do(q{DELETE FROM watched_sources WHERE id = ? AND target_id = ?}, undef, $ws_id, $id);
    $c->log_audit('delete_watched_source', 'watched_source', $ws_id);
    $c->flash(success => 'Watched source removed.');
    $c->redirect_to("/targets/$id/watched-sources");
}

1;
