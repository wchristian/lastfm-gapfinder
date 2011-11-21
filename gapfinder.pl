use 5.012;
use strict;
use warnings;

package gapfinder;

use Net::LastFMAPI;
use List::Util qw(sum);
use Config::INI::Reader;
no warnings 'once';

run();
exit;

sub run {
    my $config = Config::INI::Reader->read_file( 'config.ini' );
    local $Net::LastFMAPI::api_key = $config->{_}{api_key};
    local $Net::LastFMAPI::secret  = $config->{_}{secret};
    local $Net::LastFMAPI::json    = 1;
    local $Net::LastFMAPI::cache   = 1;

    my @artists = values %{ $config->{artists} };

    my %tracks = get_collapsed_tracks( map { [ "artist.getTopTracks", artist => $_ ] } @artists );
    my %my_tracks = get_collapsed_tracks( [ "user.getTopTracks", user => $config->{_}{user} ] );

    my @tracks = values %tracks;
    my %listener_avgs;
    for my $artist ( @artists ) {
        my @artist_tracks = grep { $_->{artist}{name} eq $artist } @tracks;
        $listener_avgs{$artist} = sum( 0, map { $_->{listeners} } @artist_tracks ) / @artist_tracks;
    }

    @tracks = grep { $_->{listeners} >= $listener_avgs{ $_->{artist}{name} } } map { $tracks{$_} } sort keys %tracks;

    for my $track ( @tracks ) {
        next if !$my_tracks{ $track->{name} };

        $track->{correction} = correction( $track );
        $my_tracks{ $track->{correction} } = $my_tracks{ $track->{name} } if $track->{correction};
    }

    my @missing_tracks;
    for my $track ( @tracks ) {
        next if $my_tracks{ $track->{name} };

        $track->{correction} ||= correction( $track );
        next if $track->{correction} and $my_tracks{ $track->{correction} };

        push @missing_tracks, $track;
    }

    say sprintf "% 4d : %s" . ( $_->{correction} ? " : (%s)" : "" ), $_->{"\@attr"}{rank}, $_->{name}, $_->{correction}
      for @missing_tracks;

    return;
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
    my @responses = map paged_request( @{$_} ), @requests;
    my @tracks = map { @{ $_->{"toptracks"}{"track"} } } @responses;
    my %tracks = map { $_->{name} => $_ } @tracks;
    return %tracks;
}

sub paged_request {
    my ( $method, %request ) = @_;
    my @responses;
    $request{page} = 1;
    my $total_pages;
    while ( !$total_pages or $request{page} <= $total_pages ) {
        my $res = lastfm( $method, %request );
        push @responses, $res;
        $request{page}++;
        $total_pages = $res->{"toptracks"}{"\@attr"}{totalPages};
        last if !$total_pages;
    }
    return @responses;
}
