use 5.012;
use strict;
use warnings;

package gapfinder;

use Encode;
use Net::LastFMAPI 0.4;
use List::Util qw(sum);
use Config::INI::Reader;
no warnings 'once';
use Smart::Comments;

run();
exit;

sub run {
    my $config = Config::INI::Reader->read_file( 'config.ini' );
    local $Net::LastFMAPI::api_key = $config->{_}{api_key};
    local $Net::LastFMAPI::secret  = $config->{_}{secret};
    local $Net::LastFMAPI::cache   = 1;

    binmode STDOUT, ":utf8";

    my %all_my_tracks = get_collapsed_tracks( [ "user.getTopTracks", user => $config->{_}{user} ] );
    my @artists = values %{ $config->{artists} || {} };
    @artists = loved_artists( $config->{_}{user} ) if !@artists;


    for my $artist ( sort @artists ) {
        say "\n$artist\n";

        my $my_tracks = $all_my_tracks{$artist};

        my @tracks = all_rows( "artist.getTopTracks", artist => $artist );

        if ( !@tracks ) {
            warn "Artist '$artist' has no tracks.";
            next;
        }

        if ( @tracks > 20 ) {
            my $listener_avg = $config->{_}{strictness} * sum( 0, map { $_->{listeners} } @tracks ) / @tracks;

            @tracks = grep { $_->{listeners} >= $listener_avg } @tracks;
        }

        for my $track ( @tracks ) {    ### |===[%]     |
            next if !$my_tracks->{ $track->{name} };

            $track->{correction} = correction( $track );
            $my_tracks->{ $track->{correction} } = $my_tracks->{ $track->{name} } if $track->{correction};
        }

        my @missing_tracks;
        for my $track ( @tracks ) {    ### |===[%]     |
            next if $my_tracks->{ $track->{name} };

            $track->{correction} = correction( $track ) if !exists $track->{correction};
            next if $track->{correction} and $my_tracks->{ $track->{correction} };

            push @missing_tracks, $track;
        }

        say sprintf "% 4d : %s" . ( $_->{correction} ? " : (%s)" : "" ), $_->{"\@attr"}{rank}, $_->{name},
          $_->{correction}
          for @missing_tracks;
    }

    return;
}

sub loved_artists {
    my ( $user ) = @_;

    my @my_loved_tracks = all_rows( "user.getLovedTracks", user => $user );
    my %loved_artists = map { $_->{artist}{name} => 1 } @my_loved_tracks;
    my @artists = keys %loved_artists;

    return @artists;
}

sub correction {
    my ( $track ) = @_;

    my $api_correction = lastfm( "track.getCorrection", artist => $track->{artist}{name}, track => $track->{name} );
    return $api_correction->{corrections}{correction}{track}{name} if ref $api_correction->{corrections};

    my $man_correction = eval { manual_correction()->{ $track->{artist}{name} }{ $track->{name} } };
    return $man_correction if $man_correction;

    return;
}

sub manual_correction {
    { "Savage Garden" => { "To The Moon And Back" => "To The Moon & Back", }, };
}

sub get_collapsed_tracks {
    my ( @requests ) = @_;
    my @tracks = map all_rows( @{$_} ), @requests;
    my %tracks;
    $tracks{ $_->{artist}{name} }{ $_->{name} } = $_ for @tracks;
    return %tracks;
}

sub all_rows {
    my $iter = lastfm_iter( @_ );
    my @rows;
    while ( my $row = eval { $iter->() } ) {    ### |===[%]     |
        push @rows, $row;
    }
    return @rows;
}
