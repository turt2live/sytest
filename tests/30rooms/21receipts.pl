use List::Util qw( first );

sub find_receipt
{
   my ( $body, %args ) = @_;

   my $room_id  = $args{room_id} or croak "Need room_id";
   my $user_id  = $args{user_id} or croak "Need user_id";
   my $type     = $args{type}    or croak "Need type";

   my $receipts = $body->{receipts};

   my ( $receipt ) = first {
      $_->{room_id} eq $room_id and $_->{type} eq "m.receipt"
   } @$receipts;

   my $content = $receipt->{content};

   # Try to find an event ID for that user
   foreach my $event_id ( keys %$content ) {
      exists $content->{$event_id} or next;
      exists $content->{$event_id}{$type} or next;

      exists $content->{$event_id}{$type}{$user_id} and
         return $event_id => $content->{$event_id}{$type}{$user_id};
   }

   return ();
}

multi_test "Read receipts are visible to /initialSync",
   requires => [ local_user_and_room_preparers(),
                 qw( can_post_room_receipts )],

   do => sub {
      my ( $user, $room_id ) = @_;

      my $user_id = $user->user_id;

      # We need an event ID in the room. The ID of our own member event seems
      # reasonable. Lets fetch it.
      my $member_event_id;
      my $message_event_id;

      # TODO: currently have to go the long way around finding it; see SPEC-264
      matrix_get_room_state( $user, $room_id )->then( sub {
         my ( $state ) = @_;

         my $member_event = first {
            $_->{type} eq "m.room.member" and $_->{state_key} eq $user->user_id
         } @$state;

         $member_event_id = $member_event->{event_id};

         matrix_advance_room_receipt( $user, $room_id, "m.read" => $member_event_id )
      })->then( sub {
         matrix_initialsync( $user )
      })->then( sub {
         my ( $body ) = @_;

         require_json_keys( $body, qw( receipts ));
         require_json_list( my $receipts = $body->{receipts} );

         log_if_fail "initialSync receipts", $receipts;

         my ( $event_id, $user_read_receipt ) = find_receipt( $body,
            room_id  => $room_id,
            user_id  => $user_id,
            type     => "m.read",
         ) or die "Expected to find an m.read in $room_id from $user_id";

         $event_id eq $member_event_id or
            die "Expected user's read recept to acknowledge up to $member_event_id";

         require_json_keys( $user_read_receipt, qw( ts ));
         require_json_number( $user_read_receipt->{ts} );

         pass "First m.read receipt is available";

         # Now try advancing the receipt by posting a message
         matrix_send_room_text_message( $user, $room_id, body => "a message" );
      })->then( sub {
         ( $message_event_id ) = @_;

         matrix_advance_room_receipt( $user, $room_id, "m.read" => $message_event_id );
      })->then( sub {
         matrix_initialsync( $user );
      })->then( sub {
         my ( $body ) = @_;

         my ( $event_id, $user_read_receipt ) = find_receipt( $body,
            room_id  => $room_id,
            user_id  => $user_id,
            type     => "m.read",
         ) or die "Expected to find an m.read in $room_id from $user_id";

         $event_id eq $message_event_id or
            die "Expected user's read receipt to have advanced to $message_event_id";

         pass "Updated m.read receipt is available";

         # Now lets check that they are monotonically racheted
         matrix_advance_room_receipt( $user, $room_id, "m.read" => $member_event_id );
      })->then( sub {
         matrix_initialsync( $user );
      })->then( sub {
         my ( $body ) = @_;

         my ( $event_id ) = find_receipt( $body,
            room_id  => $room_id,
            user_id  => $user_id,
            type     => "m.read",
         ) or die "Expected to find an m.read in $room_id from $user_id";

         $event_id eq $message_event_id or
            die "Expected user's read receipt to still be at $message_event_id";

         Future->done(1);
      });
   };

test "Read receipts are sent as events",
   requires => [ local_user_and_room_preparers(),
                 qw( can_post_room_receipts )],

   do => sub {
      my ( $user, $room_id ) = @_;

      # We need an event ID in the room. The ID of our own member event seems
      # reasonable. Lets fetch it.
      my $event_id;

      # TODO: currently have to go the long way around finding it; see SPEC-264
      matrix_get_room_state( $user, $room_id )->then( sub {
         my ( $state ) = @_;

         my $member_event = first {
            $_->{type} eq "m.room.member" and $_->{state_key} eq $user->user_id
         } @$state;

         $event_id = $member_event->{event_id};

         matrix_advance_room_receipt( $user, $room_id, "m.read" => $event_id )
      })->then( sub {
         await_event_for( $user, sub {
            my ( $event ) = @_;

            return unless $event->{type} eq "m.receipt";

            require_json_keys( $event, qw( type room_id content ));
            return unless $event->{room_id} eq $room_id;

            log_if_fail "Event", $event;

            my $content = $event->{content};
            exists $content->{$event_id} or return;
            exists $content->{$event_id}{"m.read"} or return;
            my $user_read_receipt = $content->{$event_id}{"m.read"}{ $user->user_id } or
               return;

            require_json_keys( $user_read_receipt, qw( ts ));
            require_json_number( $user_read_receipt->{ts} );

            return 1;
         })
      });
   };
