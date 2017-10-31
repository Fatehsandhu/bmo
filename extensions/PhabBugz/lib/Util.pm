# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::Util;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::User;
use Bugzilla::Util qw(trim);
use Bugzilla::Extension::PhabBugz::Constants;

use JSON::XS qw(encode_json decode_json);
use List::Util qw(first);
use LWP::UserAgent;

use base qw(Exporter);

our @EXPORT = qw(
    add_comment_to_revision
    add_security_sync_comments
    create_revision_attachment
    create_private_revision_policy
    create_project
    edit_revision_policy
    get_attachment_revisions
    get_bug_role_phids
    get_members_by_bmo_id
    get_members_by_phid
    get_project_phid
    get_revisions_by_ids
    get_revisions_by_phids
    get_security_sync_groups
    intersect
    is_attachment_phab_revision
    make_revision_private
    make_revision_public
    request
    set_project_members
    set_revision_subscribers
);

sub get_revisions_by_ids {
    my ($ids) = @_;

    my $data = {
        queryKey => 'all',
        constraints => {
            ids => $ids
        }
    };

    my $result = request('differential.revision.search', $data);

    ThrowUserError('invalid_phabricator_revision_id')
        unless (exists $result->{result}{data} && @{ $result->{result}{data} });

    return @{$result->{result}{data}};
}

<<<<<<< HEAD
sub get_revisions_by_phids {
    my ($phids) = @_;

    my $data = {
        queryKey => 'all',
        constraints => {
            phids => $phids
        }
    };

    my $result = request('differential.revision.search', $data);

    ThrowUserError('invalid_phabricator_revision_id')
        unless (exists $result->{result}{data} && @{ $result->{result}{data} });

    return $result->{result}{data};
}

||||||| merged common ancestors
=======
sub get_revisions_by_phids {
    my ($phids) = @_;

    my $data = {
        queryKey => 'all',
        constraints => {
            phids => $phids
        }
    };

    my $result = request('differential.revision.search', $data);

    ThrowUserError('invalid_phabricator_revision_id')
        unless (exists $result->{result}{data} && @{ $result->{result}{data} });

    return @{$result->{result}{data}};
}

>>>>>>> e969e034646a97750d13e66210f50c842ede4b8c
sub create_revision_attachment {
    my ( $bug, $revision_id, $revision_title ) = @_;

    my $phab_base_uri = Bugzilla->params->{phabricator_base_uri};
    ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

    my $revision_uri = $phab_base_uri . "D" . $revision_id;

    # Check for previous attachment with same revision id.
    # If one matches then return it instead. This is fine as
    # BMO does not contain actual diff content.
    my @review_attachments = grep { is_attachment_phab_revision($_) } @{ $bug->attachments };
    my $review_attachment = first { trim($_->data) eq $revision_uri } @review_attachments;
    return $review_attachment if defined $review_attachment;

    # No attachment is present, so we can now create new one
    my $is_shadow_db = Bugzilla->is_shadow_db;
    Bugzilla->switch_to_main_db if $is_shadow_db;

    my $old_user = Bugzilla->user;
    _set_phab_user();

    my $dbh = Bugzilla->dbh;
    $dbh->bz_start_transaction;

    my ($timestamp) = $dbh->selectrow_array("SELECT NOW()");

    my $attachment = Bugzilla::Attachment->create(
        {
            bug         => $bug,
            creation_ts => $timestamp,
            data        => $revision_uri,
            description => $revision_title,
            filename    => 'phabricator-D' . $revision_id . '-url.txt',
            ispatch     => 0,
            isprivate   => 0,
            mimetype    => PHAB_CONTENT_TYPE,
        }
    );

    $bug->update($timestamp);
    $attachment->update($timestamp);

    $dbh->bz_commit_transaction;
    Bugzilla->switch_to_shadow_db if $is_shadow_db;

    Bugzilla->set_user($old_user);

    return $attachment;
}

sub intersect {
    my ($list1, $list2) = @_;
    my %e = map { $_ => undef } @{$list1};
    return grep { exists( $e{$_} ) } @{$list2};
}

sub get_bug_role_phids {
    my ($bug) = @_;

    my @bug_users = ( $bug->reporter );
    push(@bug_users, $bug->assigned_to)
        if $bug->assigned_to->email !~ /^nobody\@mozilla\.org$/;
    push(@bug_users, $bug->qa_contact) if $bug->qa_contact;
    push(@bug_users, @{ $bug->cc_users }) if @{ $bug->cc_users };

    return get_members_by_bmo_id(\@bug_users);
}

sub create_private_revision_policy {
    my ($bug, $groups) = @_;

    my $data = {
        objectType => 'DREV',
        default    => 'deny',
        policy     => [
            {
                action => 'allow',
                rule   => 'PhabricatorSubscriptionsSubscribersPolicyRule',
            }
        ]
    };

    if(scalar @$groups gt 0) {
        my $project_phids = [];
        foreach my $group (@$groups) {
            my $phid = get_project_phid('bmo-' . $group);
            push(@$project_phids, $phid) if $phid;
        }

        ThrowUserError('invalid_phabricator_sync_groups') unless @$project_phids;

        push(@{ $data->{policy} },
            {
                action => 'allow',
                rule   => 'PhabricatorProjectsPolicyRule',
                value  => $project_phids,
            }
        );
    }
    else {
        push(@{ $data->{policy} },
            {
                action => 'allow',
                value  => 'admin',
            }
        );
    }

    my $result = request('policy.create', $data);
    return $result->{result}{phid};
}

sub make_revision_public {
    my ($revision_phid) = @_;
    return request('differential.revision.edit', {
        transactions => [
            {
                type  => 'view',
                value => 'public'
            },
            {
                type  => 'edit',
                value => 'users'
            }
        ],
        objectIdentifier => $revision_phid
    });
}

sub make_revision_private {
    my ($revision_phid) = @_;
    return request('differential.revision.edit', {
        transactions => [
            {
                type  => "view",
                value => "admin"
            },
            {
                type  => "edit",
                value => "admin"
            }
        ],
        objectIdentifier => $revision_phid
    });
}

sub edit_revision_policy {
    my ($revision_phid, $policy_phid, $subscribers) = @_;

    my $data = {
        transactions => [
            {
                type  => 'view',
                value => $policy_phid
            },
            {
                type  => 'edit',
                value => $policy_phid
            }
        ],
        objectIdentifier => $revision_phid
    };

    if (@$subscribers) {
        push(@{ $data->{transactions} }, {
            type  => 'subscribers.set',
            value => $subscribers
        });
    }

    return request('differential.revision.edit', $data);
}

sub set_revision_subscribers {
    my ($revision_phid, $subscribers) = @_;

    my $data = {
        transactions => [
            {
                type  => 'subscribers.set',
                value => $subscribers
            }
        ],
        objectIdentifier => $revision_phid
    };

    return request('differential.revision.edit', $data);
}

sub add_comment_to_revision {
    my ($revision_phid, $comment) = @_;

    my $data = {
        transactions => [
            {
                type  => 'comment',
                value => $comment
            }
        ],
        objectIdentifier => $revision_phid
    };
    return request('differential.revision.edit', $data);
}

sub get_project_phid {
    my $project = shift;

    my $data = {
        queryKey => 'all',
        constraints => {
            name => $project
        }
    };

    my $result = request('project.search', $data);
    return undef
        unless (exists $result->{result}{data} && @{ $result->{result}{data} });

    return $result->{result}{data}[0]{phid};
}

sub create_project {
    my ($project, $description, $members) = @_;

    my $data = {
        transactions => [
            { type => 'name',  value => $project           },
            { type => 'description', value => $description },
            { type => 'edit',  value => 'admin'            },
            { type => 'join',  value => 'admin'            },
            { type => 'view',  value => 'admin'            },
            { type => 'icon',  value => 'group'            },
            { type => 'color', value => 'red'              }
        ]
    };

    my $result = request('project.edit', $data);
    return $result->{result}{object}{phid};
}

sub set_project_members {
    my ($project_id, $phab_user_ids) = @_;

    my $data = {
        objectIdentifier => $project_id,
        transactions => [
            { type => 'members.set',  value => $phab_user_ids }
        ]
    };

    my $result = request('project.edit', $data);
    return $result->{result}{object}{phid};
}

sub get_members_by_bmo_id {
    my $users = shift;

    my $data = {
        accountids => [ map { $_->id } @$users ]
    };

    my $result = request('bmoexternalaccount.search', $data);
    return [] if (!$result->{result});

    my @phab_ids;
    foreach my $user (@{ $result->{result} }) {
        push(@phab_ids, $user->{phid})
          if ($user->{phid} && $user->{phid} =~ /^PHID-USER/);
    }

    return \@phab_ids;
}

sub get_members_by_phid {
    my $phids = shift;

    my $data = { phids => $phids };

    my $result = request('bugzilla.account.search', $data);

    my @bmo_ids;
    foreach my $user (@{ $result->{result} }) {
        push(@bmo_ids, $user->{id})
          if ($user->{phid} && $user->{phid} =~ /^PHID-USER/);
    }

    return \@bmo_ids;
}

sub is_attachment_phab_revision {
    my ($attachment, $include_obsolete) = @_;
    return ($attachment->contenttype eq PHAB_CONTENT_TYPE
            && ($include_obsolete || !$attachment->isobsolete)
            && $attachment->attacher->login eq PHAB_AUTOMATION_USER) ? 1 : 0;
}

sub get_attachment_revisions {
    my $bug = shift;

    my @revisions;

    my @attachments =
      grep { is_attachment_phab_revision($_) } @{ $bug->attachments() };

    if (@attachments) {
        my @revision_ids;
        foreach my $attachment (@attachments) {
            my ($revision_id) =
              ( $attachment->filename =~ PHAB_ATTACHMENT_PATTERN );
            next if !$revision_id;
            push( @revision_ids, int($revision_id) );
        }

        if (@revision_ids) {
            @revisions = get_revisions_by_ids( \@revision_ids );
        }
    }

    return @revisions;
}

sub request {
    my ($method, $data) = @_;
    my $request_cache = Bugzilla->request_cache;
    my $params        = Bugzilla->params;

    my $ua = $request_cache->{phabricator_ua};
    unless ($ua) {
        $ua = $request_cache->{phabricator_ua} = LWP::UserAgent->new(timeout => 10);
        if ($params->{proxy_url}) {
            $ua->proxy('https', $params->{proxy_url});
        }
        $ua->default_header('Content-Type' => 'application/x-www-form-urlencoded');
    }

    my $phab_api_key = $params->{phabricator_api_key};
    ThrowUserError('invalid_phabricator_api_key') unless $phab_api_key;
    my $phab_base_uri = $params->{phabricator_base_uri};
    ThrowUserError('invalid_phabricator_uri') unless $phab_base_uri;

    my $full_uri = $phab_base_uri . '/api/' . $method;

    $data->{__conduit__} = { token => $phab_api_key };

    my $response = $ua->post($full_uri, { params => encode_json($data) });

    ThrowCodeError('phabricator_api_error', { reason => $response->message })
      if $response->is_error;

    my $result;
    my $result_ok = eval { $result = decode_json( $response->content); 1 };
    if ( !$result_ok ) {
        ThrowCodeError(
            'phabricator_api_error',
            { reason => 'JSON decode failure' } );
    }

    return $result;
}

sub get_security_sync_groups {
    my $bug = shift;

    my $phab_sync_groups = Bugzilla->params->{phabricator_sync_groups}
        || ThrowUserError('invalid_phabricator_sync_groups');
    my $sync_group_names = [ split('[,\s]+', $phab_sync_groups) ];

    my $bug_groups = $bug->groups_in;
    my $bug_group_names = [ map { $_->name } @$bug_groups ];

    my @set_groups = intersect($bug_group_names, $sync_group_names);

    return @set_groups;
}

sub _set_phab_user {
    my $user = Bugzilla::User->new( { name => PHAB_AUTOMATION_USER } );
    $user->{groups} = [ Bugzilla::Group->get_all ];
    Bugzilla->set_user($user);
}

sub add_security_sync_comments {
    my ($revisions, $bug) = @_;

    my $phab_error_message = 'Revision is being made private due to unknown Bugzilla groups.';

    foreach my $revision (@$revisions) {
        add_comment_to_revision( $revision->{phid}, $phab_error_message );
    }

    my $num_revisions = scalar @$revisions;
    my $bmo_error_message =
    ( $num_revisions > 1
    ? $num_revisions.' revisions were'
    : 'One revision was' )
    . ' made private due to unknown Bugzilla groups.';

    my $old_user = Bugzilla->user;
    _set_phab_user();

    $bug->add_comment( $bmo_error_message, { isprivate => 0 } );

    my $bug_changes = $bug->update();
    $bug->send_changes($bug_changes);

    Bugzilla->set_user($old_user);
}

1;
