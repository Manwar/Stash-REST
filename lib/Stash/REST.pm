package Stash::REST;
use strict;
use 5.008_005;
our $VERSION = '0.01';

use Moo;
use warnings;
use utf8;
use URI;
use JSON;
use HTTP::Request::Common qw(GET POST DELETE HEAD);
use Carp qw/confess/;

has 'do_request' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a CodeRef" unless ref $_[0] eq 'CODE'},
    required => 1
);
has 'stash' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a HashRef" unless ref $_[0] eq 'HASH'},
    default => sub { {} }
);

has 'fixed_headers' => (
    is => 'rw',
    isa => sub {die "$_[0] is not a ArrayRef" unless ref $_[0] eq 'ARRAY'},
    default => sub { [] }
);

around 'stash' => sub {
    my $orig  = shift;
    my $c     = shift;
    my $stash = $orig->($c);

    if (@_) {
        return $stash->{ $_[0] } if ( @_ == 1 && ref $_[0] eq '' );

        my $new_stash = @_ > 1 ? {@_} : $_[0];
        die('stash takes a hash or hashref') unless ref $new_stash;
        foreach my $key ( keys %$new_stash ) {
            $stash->{$key} = $new_stash->{$key};
        }
    }

    return $stash;
};

sub _capture_args {
    my ($self, @params) = @_;
    my ($uri, $data, %conf);

    confess 'rest_post invalid number of params' if @params < 1;

    $uri = shift @params;
    confess 'rest_post invalid uri param' if ref $uri ne '' && ref $uri ne 'ARRAY';

    $uri = join '/', @$uri if ref $uri eq 'ARRAY';

    if (scalar @params % 2 == 0){
        %conf = @params;
        $data = exists $conf{data} ? $conf{data} : [];
    }else{
        $data = pop @params;
        %conf = @params;
    }

    confess 'rest_post param $data invalid' unless ref $data eq 'ARRAY';

    return ($self, $uri, $data, %conf);
}

sub rest_put {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->rest_post(
        $url,
        code => ( exists $conf{is_fail} ? 400 : 202 ),
        %conf,
        method => 'PUT',
        $data
    );
}

sub rest_head {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'HEAD',
        $data
    );
}

sub rest_delete {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->rest_post(
        $url,
        code => 204,
        %conf,
        method => 'DELETE',
        $data
    );
}

sub rest_get {
    my ($self, $url, $data, %conf) = &_capture_args(@_);

    $self->rest_post(
        $url,
        code => 200,
        %conf,
        method => 'GET',
        $data
    );
}


sub rest_post {
    my ($self, $url, $data, %conf) = &_capture_args(@_);



    my $is_fail = exists $conf{is_fail} && $conf{is_fail};

    my $code = $conf{code};
    $code ||= $is_fail ? 400 : 201;



    my $stashkey = exists $conf{stash} ? $conf{stash} : undef;

    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );

    my $req;

    if ( !exists $conf{files} ) {
        $req = POST $url, $data, @headers;
    }
    else {
        $conf{files}{$_} = [ $conf{files}{$_} ] for keys %{ $conf{files} };

        $req = POST $url,
          @headers,
          'Content-Type' => 'form-data',
          Content => [ @$data, %{ $conf{files} } ];
    }

    $req->method( $conf{method} ) if exists $conf{method};

    my $res = eval{$self->do_request()->($req)};
    confess "request died: $@" if $@;



    #is( $res->code, $code, $name . ' status code is ' . $code );
    confess 'response expected fail and it is successed' if $is_fail && $res->is_success;
    confess 'response expected success and it is failed' if !$is_fail && !$res->is_success;

    confess 'response code [',$res->code,'] diverge expected [',$code,']' if $code != $res->code;

    return '' if $code == 204;
    return $res if exists $conf{method} && $conf{method} eq 'HEAD';

    my $obj = eval { decode_json( $res->content ) };
    #fail($@) if $@;

    if ($stashkey) {
        $self->stash->{$stashkey} = $obj;

        $self->stash( $stashkey . '.prepare_request' => $conf{prepare_request} ) if exists $conf{prepare_request};

        if ( $code == 201 ) {
            $self->stash( $stashkey . '.id' => $obj->{id} ) if exists $obj->{id};

            my $item_url = $res->header('Location');

            if ($item_url){
                $self->stash->{$stashkey . '.url'} = $item_url ;

                $self->rest_reload($stashkey);
            }else{
                confess 'requests with response code 201 should contain header Location';
            }
        }
    }

    if ( $stashkey && exists $conf{list} ) {

        $self->stash( $stashkey . '.list-url' => $url );

        $self->rest_reload_list($stashkey);

    }

    return $obj;
}


sub rest_reload {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;


    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.url' };

    confess "can't stash $stashkey.url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;

    confess 'prepare_request must be a coderef'
        if $prepare_request && ref $prepare_request ne 'CODE';

    my $req = POST $item_url, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;

    my $res = $self->do_request()->($req);

    confess 'request code diverge expected' if $code != $res->code;

    my $obj;
    if ( $res->code == 200 ) {
        $obj = eval { decode_json( $res->content ) };

        $self->stash( $stashkey . '.get' => $obj );
    }
    elsif ( $res->code == 404 ) {


        # $self->stash->{ $stashkey . '.get' };
        delete $self->stash->{ $stashkey . '.id' };
        delete $self->stash->{ $stashkey . '.url' };
        delete $self->stash->{ $stashkey };

    }
    else {
        confess 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}


sub rest_reload_list {
    my $self     = shift;
    my $stashkey = shift;

    my %conf = @_;

    my $code = exists $conf{code} ? $conf{code} : 200;

    my @headers = (@{$self->fixed_headers()}, @{$conf{headers}||[]} );
    my $item_url = $self->stash->{ $stashkey . '.list-url' };

    confess "can't stash $stashkey.list-url is not valid" unless $item_url;

    my $prepare_request =
      exists $self->stash->{ $stashkey . '.prepare_request' }
      ? $self->stash->{ $stashkey . '.prepare_request' }
      : undef;
    confess 'prepare_request must be a coderef'
        if $prepare_request && ref $prepare_request ne 'CODE';

    my $req = POST $item_url, [];
    $req->method('GET');
    $prepare_request->($req) if $prepare_request;


    my $res = $self->do_request()->($req);

    confess 'request code diverge expected' if $code != $res->code;

    my $obj;
    if ( $res->code == 200 ) {
        $obj = eval { decode_json( $res->content ) };
        $self->stash( $stashkey . '.list' => $obj );
    }
    else {
        confess 'response code ' . $res->code . ' is not valid for rest_reload';
    }

    return $obj;
}

sub stash_ctx {
    my ( $self, $staname, $sub ) = @_;

    $sub->( $self->stash->{$staname} );
}


1;

__END__

=encoding utf-8

=head1 NAME

Stash::REST - Blah blah blah

=head1 SYNOPSIS

  use Stash::REST;

=head1 DESCRIPTION

Stash::REST is


=head1 METHODS


=head2 $t->stash

Copy from old Catalyst.pm, but $t->stash('foo') = $t->stash->{'foo'}

Returns a hashref to the stash, which may be used to store data and pass
it between components during a test. You can also set hash keys by
passing arguments. Unlike catalyst, it's never cleared, so, it lasts until object this destroy.

    $t->stash->{foo} = $bar;
    $t->stash( { moose => 'majestic', qux => 0 } );
    $t->stash( bar => 1, gorch => 2 ); # equivalent to passing a hashref


=head1 AUTHOR

Renato CRON E<lt>rentocron@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2015- Renato CRON

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
