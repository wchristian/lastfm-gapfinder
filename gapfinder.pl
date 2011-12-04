use 5.012;
use strict;
use warnings;

package gapfinder;

use Encode;
use Net::LastFMAPI 0.4;
use List::Util qw(sum);
use Config::INI::Reader;
use Try::Tiny;
no warnings 'once';

use Devel::Comments;

{
    my $old_dc_print = \&Devel::Comments::Print_for;
    no warnings 'redefine';
    *Devel::Comments::Print_for = sub {
        my @args = @_;
        if ( ( caller( 1 ) )[3] eq 'Devel::Comments::for_progress' ) {
            $_ =~ s/\n//g for @args;
        }
        $old_dc_print->( @args );
    };
}

run();
exit;

sub run {
    my $config = Config::INI::Reader->read_file( 'config.ini' );
    local $Net::LastFMAPI::api_key = $config->{_}{api_key};
    local $Net::LastFMAPI::secret  = $config->{_}{secret};

    binmode STDOUT, ":utf8";

    my ( $all_my_tracks, $rec_artists, @artists ) = retrieve_own_data( $config );

    my @per_artist_missing_tracks;
    my @errors;

    for my $artist ( sort @artists ) {    ###  |===[%]     |
        push @per_artist_missing_tracks, get_artist_tracks( $artist, $config, $all_my_tracks, \@errors );
    }

    my $max_top = 20;

    my @top_artists = @{$rec_artists};
    @top_artists = @top_artists[ 0 .. $max_top - 1 ] if @top_artists > $max_top;

    my @per_rec_artist;

    for my $artist ( map {$_->{name}} @top_artists ) {    ###  |===[%]     |
        push @per_rec_artist, get_artist_tracks( $artist, $config, $all_my_tracks, \@errors );
    }

    my @all_tracks = top_x_tracks( $max_top, \@per_artist_missing_tracks );
    my @top_rec_tracks = top_x_tracks( $max_top, \@per_rec_artist );

    say "";

    for my $data_set ( @per_artist_missing_tracks ) {
        my @tracks = @{ $data_set->{tracks} };
        next if !@tracks;

        say "$data_set->{artist}\n";

        say sprintf( "% 4d : $_->{name}" . ( $_->{correction} ? " : ($_->{correction})" : "" ), $_->{"\@attr"}{rank} )
          for @tracks;

        say "\n";
    }

    say "Top $max_top Missing Tracks";
    say sprintf(
        "% 4d : % 20s : $_->{name}" . ( $_->{correction} ? " : ($_->{correction})" : "" ),
        $_->{"\@attr"}{rank},
        $_->{artist}{name}
    ) for @all_tracks;

    say "\nTop $max_top Recommended Artists";
    for my $rec_artist ( @top_artists ) {
        my @context_artists = @{ $rec_artist->{context}{artist} };
        @context_artists = map { $_->{name} } @context_artists;

        push @errors, "Context other than artist encountered for $rec_artist->{name}"
          if keys %{ $rec_artist->{context} } > 1;

        say sprintf "% 30s : like : " . join( ', ', @context_artists ), $rec_artist->{name};
    }

    say "\nTop $max_top Recommended Tracks";
    say sprintf(
        "% 4d : % 20s : $_->{name}" . ( $_->{correction} ? " : ($_->{correction})" : "" ),
        $_->{"\@attr"}{rank},
        $_->{artist}{name}
    ) for @top_rec_tracks;

    say "";
    say for @errors;

    return;
}

sub top_x_tracks {
    my ( $max_top, $per_artist_tracks ) = @_;

    my @all_tracks = map { @{ $_->{tracks} } } @{$per_artist_tracks};
    @all_tracks = reverse sort { $a->{listeners} <=> $b->{listeners} } @all_tracks;

    @all_tracks = @all_tracks[ 0 .. $max_top - 1 ] if @all_tracks > $max_top;

    return @all_tracks;
}

sub retrieve_own_data {
    my ( $config ) = @_;

    local $Net::LastFMAPI::cache = $config->{_}{cache_own_data};

    my %all_my_tracks = get_collapsed_tracks( [ "user.getTopTracks", user => $config->{_}{user} ] );
    my @artists = values %{ $config->{artists} || {} };
    @artists = loved_artists( $config->{_}{user} ) if !@artists;

    my @rec_artists = all_rows( "user.getRecommendedArtists" );

    return ( \%all_my_tracks, \@rec_artists, @artists );
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
    my @tracks;
    for my $req ( @requests ) {
        my $iter = lastfm_iter( @{$req}, limit => 500 );
        while ( my $row = eval { $iter->() } ) {    ###  |===[%]     |
            push @tracks, $row;
        }
    }
    my %tracks;
    $tracks{ $_->{artist}{name} }{ $_->{name} } = $_ for @tracks;
    return %tracks;
}

sub all_rows {
    my $iter = lastfm_iter( @_, limit => 500 );
    my @rows;
    while ( my $row = eval { $iter->() } ) {
        push @rows, $row;
    }
    return @rows;
}

sub get_artist_tracks {
    my ( $artist, $config, $all_my_tracks, $errors ) = @_;

    local $Net::LastFMAPI::cache = $config->{_}{cache_artist_data};

    my @tracks = try {
        all_rows( "artist.getTopTracks", artist => $artist ) ;
    }
    catch {
        push @{$errors}, "Encountered error for '$artist': $_";
        return;
    };

    if ( !@tracks ) {
        push @{$errors}, "Artist '$artist' has no tracks.";
        return;
    }

    if ( @tracks > 20 ) {
        my $listener_avg = $config->{_}{strictness} * sum( 0, map { $_->{listeners} } @tracks ) / @tracks;

        @tracks = grep { $_->{listeners} >= $listener_avg } @tracks;
    }

    my $my_tracks = $all_my_tracks->{$artist};

    for my $track ( @tracks ) {
        next if !$my_tracks->{ $track->{name} };

        $track->{correction} = correction( $track );
        $my_tracks->{ $track->{correction} } = $my_tracks->{ $track->{name} } if $track->{correction};
    }

    my @missing_tracks;
    for my $track ( @tracks ) {
        next if $my_tracks->{ $track->{name} };

        $track->{correction} = correction( $track ) if !exists $track->{correction};
        next if $track->{correction} and $my_tracks->{ $track->{correction} };

        push @missing_tracks, $track;
    }

    return { artist => $artist, tracks => \@missing_tracks };
}
