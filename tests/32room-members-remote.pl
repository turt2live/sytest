test "Remote users can join room by alias",
   requires => [qw( do_request_json_for flush_events_for remote_users room_alias room_id
                    can_join_room_by_alias can_get_room_membership )],

   do => sub {
      my ( $do_request_json_for, $flush_events_for, $remote_users, $room_alias ) = @_;
      my $user = $remote_users->[0];

      $flush_events_for->( $user )->then( sub {
         $do_request_json_for->( $user,
            method => "POST",
            uri    => "/join/$room_alias",

            content => {},
         );
      });
   },

   check => sub {
      my ( $do_request_json_for, undef, $remote_users, undef, $room_id ) = @_;
      my $user = $remote_users->[0];

      $do_request_json_for->( $user,
         method => "GET",
         uri    => "/rooms/$room_id/state/m.room.member/:user_id",
      )->then( sub {
         my ( $body ) = @_;

         $body->{membership} eq "join" or
            die "Expected membership to be 'join'";

         provide can_join_remote_room_by_alias => 1;

         Future->done(1);
      });
   };

prepare "More remote room members",
   requires => [qw( do_request_json_for flush_events_for remote_users room_alias
                    can_join_remote_room_by_alias )],

   do => sub {
      my ( $do_request_json_for, $flush_events_for, $remote_users, $room_alias ) = @_;
      my ( undef, @users ) = @$remote_users;

      Future->needs_all( map {
         my $user = $_;

         $flush_events_for->( $user )->then( sub {
            $do_request_json_for->( $user,
               method => "POST",
               uri    => "/join/$room_alias",

               content => {},
            );
         });
      } @users );
   };

test "New room members see their own join event",
   requires => [qw( await_event_for remote_users room_id
                    can_join_remote_room_by_alias )],

   await => sub {
      my ( $await_event_for, $remote_users, $room_id ) = @_;

      Future->needs_all( map {
         my $user = $_;

         $await_event_for->( $user, sub {
            my ( $event ) = @_;
            return unless $event->{type} eq "m.room.member";

            json_keys_ok( $event, qw( type room_id user_id membership ));
            return unless $event->{room_id} eq $room_id;
            return unless $event->{user_id} eq $user->user_id;

            $event->{membership} eq "join" or
               die "Expected user membership as 'join'";

            return 1;
         });
      } @$remote_users );
   };

test "New room members also see original members' presence",
   requires => [qw( await_event_for user remote_users
                    can_join_remote_room_by_alias )],

   # Currently this test fails due to a Synapse bug. May be related to
   #   SYN-72 or SYN-81
   expect_fail => 1,

   await => sub {
      my ( $await_event_for, $first_user, $remote_users ) = @_;

      Future->needs_all( map {
         my $user = $_;

         $await_event_for->( $user, sub {
            my ( $event ) = @_;
            return unless $event->{type} eq "m.presence";
            json_keys_ok( $event, qw( type content ));
            json_keys_ok( my $content = $event->{content}, qw( user_id presence ));

            return unless $content->{user_id} eq $first_user->user_id;

            return 1;
         });
      } @$remote_users );
   };

test "Existing members see new members' join events",
   requires => [qw( await_event_for user remote_users room_id
                    can_join_remote_room_by_alias )],

   await => sub {
      my ( $await_event_for, $user, $remote_users, $room_id ) = @_;

      Future->needs_all( map {
         my $other_user = $_;

         $await_event_for->( $user, sub {
            my ( $event ) = @_;
            return unless $event->{type} eq "m.room.member";
            json_keys_ok( $event, qw( type room_id user_id membership ));
            return unless $event->{room_id} eq $room_id;
            return unless $event->{user_id} eq $other_user->user_id;

            $event->{membership} eq "join" or
               die "Expected user membership as 'join'";

            return 1;
         });
      } @$remote_users );
   };

test "Existing members see new member's presence",
   requires => [qw( await_event_for user remote_users
                    can_join_remote_room_by_alias )],

   await => sub {
      my ( $await_event_for, $user, $remote_users ) = @_;

      Future->needs_all( map {
         my $other_user = $_;

         $await_event_for->( $user, sub {
            my ( $event ) = @_;
            return unless $event->{type} eq "m.presence";
            json_keys_ok( $event, qw( type content ));
            json_keys_ok( my $content = $event->{content}, qw( user_id presence ));
            return unless $content->{user_id} eq $other_user->user_id;

            return 1;
         });
      } @$remote_users );
   };
