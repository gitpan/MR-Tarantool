package MR::Tarantool::Box;

=pod

=head1 NAME

MR::Tarantool::Box

A driver for an efficient Tarantool/Box NoSQL in-memory storage.

=head1 SYNOPSIS

    my $box = MR::Tarantool::Box->new({
        servers => "127.0.0.1:33013",
        name    => "My Box",              # primarily used for debug purposes
        spaces => [ {
            indexes => [ {
                index_name   => 'idx1',
                keys         => [0],
            }, {
                index_name   => 'idx2',
                keys         => [1],
            }, ],
            space         => 1,           # space id, as set in Tarantool/Box config
            name          => "primary",   # self-descriptive space-id
            format        => "QqLlSsCc&", # pack()-compatible, Qq must be supported by perl itself, & stands for byte-string.
            default_index => 'idx1',
        }, {
            #...
        } ],
        default_space => "primary",

        timeout   => 1,
        retry     => 3,
        debug     => 9,                   # output to STDERR some debugging info
        raise     => 0,                   # dont raise an exception in case of error
    });

    $box->Insert(1,2,3,4,5,6,7,8,"asdf") or die $box->ErrorStr;
    $box->Insert(1,2,3,4,5,6,7,8,"asdf",{space => "primary"}) or die $box->ErrorStr;

    my $tuples = $box->Select(1);
    my $tuples = $box->Select(1,{space => "primary", use_index => "idx1"});

=head1 DESCRIPTION

=cut

use strict;
use warnings;
use Scalar::Util qw/looks_like_number/;
use List::MoreUtils qw/each_arrayref/;
use Time::HiRes qw/sleep/;

use MR::IProto ();

use constant {
    WANT_RESULT       => 1,
    INSERT_ADD        => 2,
    INSERT_REPLACE    => 4,
};


sub IPROTOCLASS () { 'MR::IProto' }

use vars qw/$VERSION %ERRORS/;
$VERSION = 1.4.3;

BEGIN { *confess = \&MR::IProto::confess }

%ERRORS = (
    0x00000000  => q{OK},
    0x00000100  => q{Non master connection, but it should be},
    0x00000200  => q{Illegal parametrs},
    0x00000300  => q{Uid not from this storage range},
    0x00000400  => q{Tuple is marked as read-only},
    0x00000500  => q{Tuple isn't locked},
    0x00000600  => q{Tuple is locked},
    0x00000700  => q{Failed to allocate memory},
    0x00000800  => q{Bad integrity},
    0x00000a00  => q{Unsupported command},

    0x00000b00  => q{Can't do select},

    0x00001800  => q{Can't register new user},
    0x00001a00  => q{Can't generate alert id},
    0x00001b00  => q{Can't del node},

    0x00001c00  => q{User isn't registered},
    0x00001d00  => q{Syntax error in query},
    0x00001e00  => q{Unknown field},
    0x00001f00  => q{Number value is out of range},
    0x00002000  => q{Insert already existing object},
    0x00002200  => q{Can not order result},
    0x00002300  => q{Multiple update/delete forbidden},
    0x00002400  => q{Nothing affected},
    0x00002500  => q{Primary key update forbidden},
    0x00002600  => q{Incorrect protocol version},
    0x00002700  => q{WAL failed},
    0x00003000  => q{Procedure return type is not supported in the binary protocol},
    0x00003100  => q{Tuple doesn't exist},
    0x00003200  => q{Procedure is not defined},
    0x00003300  => q{Lua error},
    0x00003400  => q{Space is disabled},
    0x00003500  => q{No such index in space},
    0x00003600  => q{Field was not found in the tuple},
    0x00003700  => q{Tuple already exists},
    0x00003800  => q{Duplicate key exists in a unique index},
    0x00003900  => q{Space does not exists},
);



=pod

=head3 new

    my $box = $class->new(\%args);

%args:

=over

=item B<spaces> => [ \%space, ... ]

%space:

=over

=item B<space> => $space_id_uint32

Space id as set in Tarantool/Box config.

=item B<name> => $space_name_string

Self-descriptive space id, which will be mapped into C<space>.

=item B<format> => $format_string

C<pack()>-compatible tuple format string, allowed formats: C<QqLlSsCc&>,
where C<&> stands for bytestring. C<Qq> usable only if perl supports
int64 itself. Tuples' fields are packed/unpacked according to this C<format>.

=item B<indexes> => [ \%index, ... ]

%index:

=over

=item B<id> => $index_id_uint32

Index id as set in Tarantool/Box config within current C<space>.
If not set, order position in C<indexes> is theated as C<id>.

=item B<name> => $index_name_string

Self-descriptive index id, which will be mapped into C<index_id>.

=item B<keys> => [ $field_no_uint32, ... ]

Properly ordered arrayref of fields' numbers which are indexed.

=back

=item B<default_index> => $default_index_name_string_or_id_uint32

Index C<id> or C<name> to be used by default for the current C<space>.
Must be set if there are more than one C<\%index>es.

=back

=item B<default_space> => $default_space_name_string_or_id_uint32

Space C<space> or C<name> to be used by default. Must be set if there are
more than one C<\%space>s.

=item B<timeout> => $timeout_fractional_seconds_float || 23

A common timeout for network operations.

=item B<select_timeout> => $select_timeout_fractional_seconds_float || 2

Select queries timeout for network operations. See L<select_retry>.

=item B<retry> => $retry_int || 1

A common retries number for network operations.

=item B<select_retry> => $select_retry_int || 3

Select queries retries number for network operations.

Sometimes we need short timeout for select's and long timeout for B<critical> update's,
because in case of timeout we B<don't know if the update has succeeded>. For the same
reason we B<can't retry> update operation.

So increasing C<timeout> and setting C<< retry => 1 >> for updates lowers possibility of
such situations (but, of course, does not exclude them at all), and guarantees that
we dont do the same more then once.

=item B<soft_retry> => $soft_retry_int || 3

A common retries number for Tarantool/Box B<temporary errors> (these marked by 1 in the
lowest byte of C<error_code>). In that case we B<know for sure> that the B<request was
declined> by Tarantool/Box for some reason (a tuple was locked for another update, for
example), and we B<can> try it again.

This is also limited by C<retry>/C<select_retry>
(depending on query type).

=item B<raise> => $raise_bool || 1

Should we raise an exceptions? If so, exceptions are raised when no more retries left and
all tries failed (with timeout, fatal, or temporary error).

=item B<debug> => $debug_level_int || 0

Debug level, 0 - print nothing, 9 - print everything

=item B<name> => $name

A string used for self-description. Mainly used for debugging purposes.

=back

=cut

sub new {
    my ($class, $arg) = @_;
    my $self;

    $arg = { %$arg };
    $self->{name}            = $arg->{name}      || ref$class || $class;
    $self->{timeout}         = $arg->{timeout}   || 23;
    $self->{retry}           = $arg->{retry}     || 1;
    $self->{retry_delay}     = $arg->{retry_delay} || 1;
    $self->{select_retry}    = $arg->{select_retry} || 3;
    $self->{softretry}       = $arg->{soft_retry} || $arg->{softretry} || 3;
    $self->{debug}           = $arg->{'debug'}   || 0;
    $self->{ipdebug}         = $arg->{'ipdebug'} || 0;
    $self->{raise}           = 1;
    $self->{raise}           = $arg->{raise} if exists $arg->{raise};
    $self->{hashify}         = $arg->{'hashify'} if exists $arg->{'hashify'};
    $self->{default_raw}     = exists $arg->{default_raw} ? $arg->{default_raw} : !$self->{hashify};
    $self->{select_timeout}  = $arg->{select_timeout} || $self->{timeout};
    $self->{iprotoclass}     = $arg->{iprotoclass} || $class->IPROTOCLASS;
    $self->{_last_error}     = 0;

    $arg->{spaces} = $arg->{namespaces} = [@{ $arg->{spaces} ||= $arg->{namespaces} || confess "no spaces given" }];
    confess "no spaces given" unless @{$arg->{spaces}};
    my %namespaces;
    for my $ns (@{$arg->{spaces}}) {
        $ns = { %$ns };
        my $namespace = defined $ns->{space} ? $ns->{space} : $ns->{namespace};
        $ns->{space} = $ns->{namespace} = $namespace;
        confess "ns[?] `space' not set" unless defined $namespace;
        confess "ns[$namespace] already defined" if $namespaces{$namespace} or $ns->{name}&&$namespaces{$ns->{name}};
        confess "ns[$namespace] no indexes defined" unless $ns->{indexes} && @{$ns->{indexes}};
        $namespaces{$namespace} = $ns;
        $namespaces{$ns->{name}} = $ns if $ns->{name};
        confess "ns[$namespace] bad format `$ns->{format}'" if $ns->{format} =~ m/[^&lLsScCqQ ]/;
        $ns->{format} =~ s/\s+//g;
        my @f = split //, $ns->{format};
        $ns->{byfield_unpack_format} = [ map { /&/ ? 'w/a*' : "x$_" } @f ];
        $ns->{field_format}  = [         map { /&/ ? 'a*'   : $_    } @f ];
        $ns->{unpack_format}  = join('', @{$ns->{byfield_unpack_format}});
        $ns->{append_for_unpack} = '' unless defined $ns->{append_for_unpack};
        $ns->{check_keys} = {};
        $ns->{string_keys} = { map { $_ => 1 } grep { $f[$_] eq '&' } 0..$#f };
        my $inames = $ns->{index_names} = {};
        my $i = -1;
        for my $index (@{$ns->{indexes}}) {
            ++$i;
            confess "ns[$namespace]index[($i)] no name given" unless length $index->{index_name};
            my $index_name = $index->{index_name};
            confess "ns[$namespace]index[$index_name($i)] no indexes defined" unless $index->{keys} && @{$index->{keys}};
            confess "ns[$namespace]index[$index_name($i)] already defined" if $inames->{$index_name} || $inames->{$i};
            $index->{id} = $i unless defined $index->{id};
            $inames->{$i} = $inames->{$index_name} = $index;
            int $_ == $_ and $_ >= 0 and $_ < @f or confess "ns[$namespace]index[$index_name] bad key `$_'" for @{$ns->{keys}};
            $ns->{check_keys}->{$_} = int !! $ns->{string_keys}->{$_} for @{$index->{keys}};
            $index->{string_keys} ||= $ns->{string_keys};
        }
        if( @{$ns->{indexes}} > 1 ) {
            confess "ns[$namespace] default_index not given" unless defined $ns->{default_index};
            confess "ns[$namespace] default_index $ns->{default_index} does not exist" unless $inames->{$ns->{default_index}};
        } else {
            $ns->{default_index} ||= 0;
        }
    }
    $self->{namespaces} = \%namespaces;
    if (@{$arg->{spaces}} > 1) {
        $arg->{default_namespace} = $arg->{default_space} if defined $arg->{default_space};
        confess "default_space not given" unless defined $arg->{default_namespace};
        confess "default_space $arg->{default_namespace} does not exist" unless $namespaces{$arg->{default_namespace}};
        $self->{default_namespace} = $arg->{default_namespace};
    } else {
        $self->{default_namespace} = $arg->{default_space} || $arg->{default_namespace} || $arg->{spaces}->[0]->{space};
        confess "default_space $self->{default_namespace} does not exist" unless $namespaces{$self->{default_namespace}};
    }
    bless $self, $class;
    $self->_connect($arg->{'servers'});
    return $self;
}

sub _debug {
    if($_[0]->{warn}) {
        &{$_[0]->{warn}};
    } else {
        warn "@_[1..$#_]\n";
    }
}

sub _connect {
    my ($self, $servers) = @_;
    $self->{server} = $self->{iprotoclass}->new({
        servers       => $servers,
        name          => $self->{name},
        debug         => $self->{'ipdebug'},
        dump_no_ints  => 1,
    });
}

=pod

=head3 Error

Last error code, or 'fail' for some network reason, oftenly a timeout.

    $box->Insert(@tuple) or die sprintf "Error %X", $box->Error; # die "Error 202"

=head3 ErrorStr

Last error code and description in a single string.

    $box->Insert(@tuple) or die $box->ErrorStr;                  # die "Error 00000202: Illegal Parameters"

=cut

sub ErrorStr {
    return $_[0]->{_last_error_msg};
}

sub Error {
    return $_[0]->{_last_error};
}

sub _chat {
    my ($self, %param) = @_;
    my $orig_unpack = delete $param{unpack};

    $param{unpack} = sub {
        my $data = $_[0];
        confess __LINE__."$self->{name}: [common]: Bad response" if length $data < 4;
        my ($full_code, @err_code) = unpack('LX[L]CSC', substr($data, 0, 4, ''));
        # $err_code[0] = severity: 0 -> ok, 1 -> transient, 2 -> permanent;
        # $err_code[1] = description;
        # $err_code[2] = da box project;
        return (\@err_code, \$data, $full_code);
    };

    my $timeout = $param{timeout} || $self->{timeout};
    my $retry = $param{retry} || $self->{retry};
    my $soft_retry = $self->{softretry};
    my $retry_count = 0;

    while ($retry > 0) {
        $retry_count++;

        $self->{_last_error} = 0x77777777;
        $self->{server}->SetTimeout($timeout);
        my $ret = $self->{server}->Chat1(%param);
        my $message;

        if (exists $ret->{ok}) {
            my ($ret_code, $data, $full_code) = @{$ret->{ok}};
            $self->{_last_error} = $full_code;
            if ($ret_code->[0] == 0) {
                my $ret = $orig_unpack->($$data,$ret_code->[2]);
                confess __LINE__."$self->{name}: [common]: Bad response (more data left)" if length $$data > 0;
                return $ret;
            }

            $self->{_last_error_msg} = $message = $ret_code->[0] == 0 ? "ok" : sprintf "Error %08X: %s", $full_code, $$data || $ERRORS{$full_code & 0xFFFFFF00} || 'Unknown error';
            $self->_debug("$self->{name}: $message") if $self->{debug} >= 1;
            if ($ret_code->[0] == 2) { #fatal error
                $self->_raise($message) if $self->{raise};
                return 0;
            }

            # retry if error is soft even in case of update e.g. ROW_LOCK
            if ($ret_code->[0] == 1 and --$soft_retry > 0) {
                --$retry if $retry > 1;
                sleep $self->{retry_delay};
                next;
            }
        } else { # timeout has caused the failure if $ret->{timeout}
            $self->{_last_error} = 'fail';
            $message ||= $self->{_last_error_msg} = $ret->{fail};
            $self->_debug("$self->{name}: $message") if $self->{debug} >= 1;
        }

        last unless --$retry;

        sleep $self->{retry_delay};
    };

    $self->_raise("no success after $retry_count tries\n") if $self->{raise};
}

sub _raise {
    my ($self, $msg) = @_;
    die "$self->{name}: $msg\n";
}

sub _validate_param {
    my ($self, $args, @pnames) = @_;
    my $param = $args && @$args && ref $args->[-1] eq 'HASH' ? {%{pop @$args}} : {};

    my %pnames = map { $_ => 1 } @pnames;
    $pnames{space} = 1;
    $pnames{namespace} = 1;
    foreach my $pname (keys %$param) {
        confess "$self->{name}: unknown param $pname\n" unless exists $pnames{$pname};
    }

    $param->{namespace} = $param->{space} if exists $param->{space} and defined $param->{space};
    $param->{namespace} = $self->{default_namespace} unless defined $param->{namespace};
    confess "$self->{name}: bad space `$param->{namespace}'" unless exists $self->{namespaces}->{$param->{namespace}};
    my $ns = $self->{namespaces}->{$param->{namespace}};
    $param->{use_index} = $ns->{default_index} unless defined $param->{use_index};
    confess "$self->{name}: bad index `$param->{use_index}'" unless exists $ns->{index_names}->{$param->{use_index}};
    $param->{index} = $ns->{index_names}->{$param->{use_index}};
    return ($param, $self->{namespaces}->{$param->{namespace}}, map { $param->{$_} } @pnames);
}

=pod

=head3 Call

Call a stored procedure. Returns an arrayref of the result tuple(s) upon success.

    my $results = $box->Call('stored_procedure_name', \@procedure_params, \%options) or die $box->ErrorStr; # Call failed
    my $result_tuple = @$results && $results->[0] or warn "Call succeeded, but returned nothing";

=over

=item B<@procedure_params>

An array of bytestrings to be passed as is to the procecedure.

=item B<%options>

=over

=item B<unpack_format>

Format to unpack the result tuple, the same as C<format> option for C<new()>

=back

=back

=cut

sub Call {
    my ($param, $namespace) = $_[0]->_validate_param(\@_, qw/flags raise unpack unpack_format/);
    my ($self, $sp_name, $tuple) = @_;

    my $flags = $param->{flags} || 0;
    local $self->{raise} = $param->{raise} if defined $param->{raise};

    $self->_debug("$self->{name}: CALL($sp_name)[${\join '   ', map {join' ',unpack'(H2)*',$_} @$tuple}]") if $self->{debug} >= 4;
    confess "All fields must be defined" if grep { !defined } @$tuple;

    confess "Bad `unpack_format` option" if exists $param->{unpack_format} and ref $param->{unpack_format} ne 'ARRAY';
    my $unpack_format = join '', map { /&/ ? 'w/a*' : "x$_" } @{$param->{unpack_format}};

    local $namespace->{unpack_format} = $unpack_format if $unpack_format; # XXX
    local $namespace->{append_for_unpack} = ''         if $unpack_format; # shit...

    $self->_chat (
        msg      => 22,
        payload  => pack("L w/a* L(w/a*)*", $flags, $sp_name, scalar(@$tuple), @$tuple),
        unpack   => $param->{unpack} || sub { $self->_unpack_select($namespace, "CALL", @_) },
        callback => $param->{callback},
    );
}

=pod

=head3 Add, Set, Replace

    $box->Add(@tuple) or die $box->ErrorStr;
    $box->Set(@tuple, { space => "main" });
    $box->Replace(@tuple, { space => "secondary" });

Insert a C<< @tuple >> into the storage into C<$options{space}> or C<default_space> space.
All of them return C<true> upon success.

All of them have the same parameters:

=over

=item B<@tuple>

A tuple to insert. All fields must be defined. All fields will be C<pack()>ed according to C<format> (see L<new>)

=item B<%options>

=over

=item B<space> => $space_id_uint32_or_name_string

Specify storage space to work on.

=back

=back

The difference between them is the behaviour concerning tuple with the same primary key:

=over

=item *

B<Add> will fail if a duplicate-key tuple B<exists> 

=item *

B<Replace> will fail if a duplicate-key tuple B<does not exists> 

=item *

B<Set> will B<overwrite> a duplicate-key tuple 

=back

=cut

sub Add { # store tuple if tuple identified by primary key _does_not_ exist
    my $param = @_ && ref $_[-1] eq 'HASH' ? pop : {};
    $param->{action} = 'add';
    $_[0]->Insert(@_[1..$#_], $param);
}

sub Set { # store tuple _anyway_
    my $param = @_ && ref $_[-1] eq 'HASH' ? pop : {};
    $param->{action} = 'set';
    $_[0]->Insert(@_[1..$#_], $param);
}

sub Replace { # store tuple if tuple identified by primary key _does_ exist
    my $param = @_ && ref $_[-1] eq 'HASH' ? pop : {};
    $param->{action} = 'replace';
    $_[0]->Insert(@_[1..$#_], $param);
}

sub Insert {
    my ($param, $namespace) = $_[0]->_validate_param(\@_, qw/_flags action/);
    my ($self, @tuple) = @_;

    $self->_debug("$self->{name}: INSERT(NS:$namespace->{namespace},TUPLE:[@{[map {qq{`$_'}} @tuple]}])") if $self->{debug} >= 3;

    my $flags = $param->{_flags} || 0;
    $param->{action} ||= 'set';
    if ($param->{action} eq 'add') {
        $flags |= INSERT_ADD;
    } elsif ($param->{action} eq 'replace') {
        $flags |= INSERT_REPLACE;
    } elsif ($param->{action} ne 'set') {
        confess "$self->{name}: Bad insert action `$param->{action}'";
    }
    my $chkkey = $namespace->{check_keys};
    my $fmt = $namespace->{field_format};
    for (0..$#tuple) {
        confess "$self->{name}: ref in tuple $_=`$tuple[$_]'" if ref $tuple[$_];
        no warnings 'uninitialized';
        if(exists $chkkey->{$_}) {
            if($chkkey->{$_}) {
                confess "$self->{name}: undefined key $_" unless defined $tuple[$_];
            } else {
                confess "$self->{name}: not numeric key $_=`$tuple[$_]'" unless looks_like_number($tuple[$_]) && int($tuple[$_]) == $tuple[$_];
            }
        }
        $tuple[$_] = pack($fmt->[$_], $tuple[$_]);
    }

    $self->_debug("$self->{name}: INSERT[${\join '   ', map {join' ',unpack'(H2)*',$_} @tuple}]") if $self->{debug} >= 4;

    $self->_chat (
        msg      => 13,
        payload  => pack("LLL (w/a*)*", $namespace->{namespace}, $flags, scalar(@tuple), @tuple),
        unpack   => sub { $self->_unpack_affected($flags, $namespace, @_) },
        callback => $param->{callback},
    );
}

sub _unpack_select {
    my ($self, $ns, $debug_prefix) = @_;
    $debug_prefix ||= "SELECT";
    confess __LINE__."$self->{name}: [$debug_prefix]: Bad response" if length $_[3] < 4;
    my $result_count = unpack('L', substr($_[3], 0, 4, ''));
    $self->_debug("$self->{name}: [$debug_prefix]: COUNT=[$result_count];") if $self->{debug} >= 3;
    my (@res);
    my $appe = $ns->{append_for_unpack};
    my $fmt  = $ns->{unpack_format};
    for(my $i = 0; $i < $result_count; ++$i) {
        confess __LINE__."$self->{name}: [$debug_prefix]: Bad response" if length $_[3] < 8;
        my ($len, $cardinality) = unpack('LL', substr($_[3], 0, 8, ''));
        $self->_debug("$self->{name}: [$debug_prefix]: ROW[$i]: LEN=[$len]; NFIELD=[$cardinality];") if $self->{debug} >= 4;
        confess __LINE__."$self->{name}: [$debug_prefix]: Bad response" if length $_[3] < $len;
        my $packed_tuple = substr($_[3], 0, $len, '');
        $self->_debug("$self->{name}: [$debug_prefix]: ROW[$i]: DATA=[@{[unpack '(H2)*', $packed_tuple]}];") if $self->{debug} >= 6;
        $packed_tuple .= $appe;
        my @tuple = eval { unpack($fmt, $packed_tuple) };
        confess "$self->{name}: [$debug_prefix]: ROW[$i]: can't unpack tuple [@{[unpack('(H2)*', $packed_tuple)]}]: $@" if !@tuple || $@;
        $self->_debug("$self->{name}: [$debug_prefix]: ROW[$i]: FIELDS=[@{[map { qq{`$_'} } @tuple]}];") if $self->{debug} >= 5;
        push @res, \@tuple;
    }
    return \@res;
}

sub _unpack_select_multi {
    my ($self, $nss, $debug_prefix) = @_;
    $debug_prefix ||= "SMULTI";
    my (@rsets);
    my $i = 0;
    for my $ns (@$nss) {
        push @rsets, $self->_unpack_select($ns, "${debug_prefix}[$i]", $_[3]);
        ++$i;
    }
    return \@rsets;
}


sub _unpack_affected {
    my ($self, $flags, $ns) = @_;

    ($flags & WANT_RESULT) ? $self->_unpack_select($ns, "AFFECTED", $_[3])->[0] : unpack('L', substr($_[3],0,4,''))||'0E0';
}

sub NPRM () { 3 }
sub _pack_keys {
    my ($self, $ns, $idx) = @_;

    my $keys   = $idx->{keys};
    my $strkey = $ns->{string_keys};
    my $fmt    = $ns->{field_format};

    if (@$keys == 1) {
        $fmt    = $fmt->[$keys->[0]];
        $strkey = $strkey->{$keys->[0]};
        foreach (@_[NPRM..$#_]) {
            ($_) = @$_ if ref $_ eq 'ARRAY';
            unless ($strkey) {
                confess "$self->{name}: not numeric key [$_]" unless looks_like_number($_) && int($_) == $_;
                $_ = pack($fmt, $_);
            }
            $_ = pack('L(w/a*)*', 1, $_);
        }
    } else {
        foreach my $k (@_[NPRM..$#_]) {
            confess "bad key [@$keys][$k][@{[ref $k eq 'ARRAY' ? (@$k) : ()]}]" unless ref $k eq 'ARRAY' and @$k and @$k <= @$keys;
            for my $i (0..$#$k) {
                unless ($strkey->{$keys->[$i]}) {
                    confess "$self->{name}: not numeric key [$i][$k->[$i]]" unless looks_like_number($k->[$i]) && int($k->[$i]) == $k->[$i];
                }
                $k->[$i] = pack($fmt->[$keys->[$i]], $k->[$i]);
            }
            $k = pack('L(w/a*)*', scalar(@$k), @$k);
        }
    }
}

sub _PackSelect {
    my ($self, $param, $namespace, @keys) = @_;
    return '' unless @keys;
    $self->_pack_keys($namespace, $param->{index}, @keys);
    my $format = "";
    if ($param->{format}) {
        my $f = $namespace->{byfield_unpack_format};
        $param->{unpack_format} = join '', map { $f->[$_->{field}] } @{$param->{format}};
        $format = pack 'l*', scalar @{$param->{format}}, map {
            $_ = { %$_ };
            if($_->{full}) {
                $_->{offset} = 0;
                $_->{length} = 'max';
            }
            $_->{length} = 0x7FFFFFFF if $_->{length} eq 'max';
            @$_{qw/field offset length/}
        } @{$param->{format}};
    }
    return pack("LLLL a* La*", $namespace->{namespace}, $param->{index}->{id}, $param->{offset} || 0, $param->{limit} || scalar(@keys), $format, scalar(@keys), join('',@keys));
}

sub _PostSelect {
    my ($self, $r, $param) = @_;
    if(!$param->{raw} && ref $param->{hashify} eq 'CODE') {
        $param->{hashify}->($param->{namespace}->{namespace}, $r);
    }
}

=pod

=head3 Select

Select tuple(s) from storage

    my $tuple  = $box->Select($key)             or $box->Error && die $box->ErrorStr;
    my $tuple  = $box->Select($key, \%options)   or $box->Error && die $box->ErrorStr;
    
    my @tuples = $box->Select(@keys)            or $box->Error && die $box->ErrorStr;
    my @tuples = $box->Select(@keys, \%options)  or $box->Error && die $box->ErrorStr;
    
    my $tuples = $box->Select(\@keys)           or die $box->ErrorStr;
    my $tuples = $box->Select(\@keys, \%options) or die $box->ErrorStr;

=over

=item B<$key>, B<@keys>, B<\@keys>

Specify keys to select. All keys must be defined.

=over

=item *

In scalar context, you can select one C<$key>, and the resulting tuple will be returned.
Check C<< $box->Error >> to see if there was an error or there is just no such key
in the storage

=item *

In list context, you can select several C<@keys>, and the resulting tuples will be returned.
Check C<< $box->Error >> to see if there was an error or there is just no such keys
in the storage

=item *

If you select C<< \@keys >> then C<< \@tuples >> will be returned upon success. @tuples will
be empty if there are no such keys, and false will be returned in case of error.

=back

=item B<%options>

=over

=item B<space> => $space_id_uint32_or_name_string

Specify storage (by id or name) space to select from.

=item B<use_index> => $index_id_uint32_or_name_string

Specify index (by id or name) to use.

=item B<hashify> => $coderef

Override C<hashify> option (see L<new>).

=item B<raw> => $bool

Don't C<hashify>.

=item B<hash_by> => $by

Return a hashref of the resultset. If you C<hashify> the result set,
then C<$by> must be a field name of the hash you return,
else it must be a number of field of the tuple.
False will be returned in case of error.

=back

=back

=cut

my @select_param_ok = qw/use_index raw want next_rows limit offset raise hashify timeout format hash_by/;
sub Select {
    confess q/Select isnt callable in void context/ unless defined wantarray;
    my ($param, $namespace) = $_[0]->_validate_param(\@_, @select_param_ok);
    my ($self, @keys) = @_;
    local $self->{raise} = $param->{raise} if defined $param->{raise};
    @keys = @{$keys[0]} if @keys && ref $keys[0] eq 'ARRAY' and 1 == @{$param->{index}->{keys}} || (@keys && ref $keys[0]->[0] eq 'ARRAY');

    $self->_debug("$self->{name}: SELECT(NS:$namespace->{namespace},IDX:$param->{use_index})[@{[map{ref$_?qq{[@$_]}:$_}@keys]}]") if $self->{debug} >= 3;

    my ($msg,$payload);
    if(exists $param->{next_rows}) {
        confess "$self->{name}: One and only one key can be used to get N>0 rows after it" if @keys != 1 || !$param->{next_rows};
        $msg = 15;
        $self->_pack_keys($namespace, $param->{index}, @keys);
        $payload = pack("LL a*", $namespace->{namespace}, $param->{next_rows}, join('',@keys)),
    } else {
        $payload = $self->_PackSelect($param, $namespace, @keys);
        $msg = $param->{format} ? 21 : 17;
    }

    local $namespace->{unpack_format} = $param->{unpack_format} if $param->{unpack_format};

    my $r = [];
    if (@keys && $payload) {
        $r = $self->_chat(
            msg      => $msg,
            payload  => $payload,
            unpack   => sub { $self->_unpack_select($namespace, "SELECT", @_) },
            retry    => $self->{select_retry},
            timeout  => $param->{timeout} || $self->{select_timeout},
            callback => $param->{callback},
        ) or return;
    }

    $param->{raw} = $self->{default_raw} unless exists $param->{raw};
    $param->{want} ||= !1;

    $self->_PostSelect($r, { hashify => $param->{hashify}||$namespace->{hashify}||$self->{hashify}, %$param, namespace => $namespace });

    if(defined(my $p = $param->{hash_by})) {
        my %h;
        if(@$r) {
            if (ref $r->[0] eq 'HASH') {
                confess "Bad hash_by `$p' for HASH" unless exists $r->[0]->{$p};
                $h{$_->{$p}} = $_ for @$r;
            } elsif(ref $r->[0] eq 'ARRAY') {
                confess "Bad hash_by `$p' for ARRAY" unless $p =~ m/^\d+$/ && $p >= 0 && $p < @{$r->[0]};
                $h{$_->[$p]} = $_ for @$r;
            } else {
                confess "i dont know how to hash_by ".ref($r->[0]);
            }
        }
        return \%h;
    }

    return $r if $param->{want} eq 'arrayref';

    if (wantarray) {
        return @{$r};
    } else {
        confess "$self->{name}: too many keys in scalar context" if @keys > 1;
        return $r->[0];
    }
}

sub SelectUnion {
    confess "not supported yet";
    my ($param) = $_[0]->_validate_param(\@_, qw/raw raise/);
    my ($self, @reqs) = @_;
    return [] unless @reqs;
    local $self->{raise} = $param->{raise} if defined $param->{raise};
    confess "bad param" if grep { ref $_ ne 'ARRAY' } @reqs;
    $param->{raw} = $self->{default_raw} unless exists $param->{raw};
    $param->{want} ||= 0;
    for my $req (@reqs) {
        my ($param, $namespace) = $self->_validate_param($req, @select_param_ok);
        $req = {
            payload   => $self->_PackSelect($param, $namespace, $req),
            param     => $param,
            namespace => $namespace,
        };
    }
    my $r = $self->_chat(
        msg      => 18,
        payload  => pack("L (a*)*", scalar(@reqs), map { $_->{payload} } @reqs),
        unpack   => sub { $self->_unpack_select_multi([map { $_->{namespace} } @reqs], "SMULTI", @_) },
        retry    => $self->{select_retry},
        timeout  => $param->{select_timeout} || $self->{timeout},
        callback => $param->{callback},
    ) or return;
    confess __LINE__."$self->{name}: something wrong" if @$r != @reqs;
    my $ea = each_arrayref $r, \@reqs;
    while(my ($res, $req) = $ea->()) {
        $self->_PostSelect($res, { hashify => $req->{namespace}->{hashify}||$self->{hashify}, %$param, %{$req->{param}}, namespace => $req->{namespace} });
    }
    return $r;
}

=pod

=head3 Delete

Delete tuple from storage. Return false upon error.

    my $n_deleted = $box->Delete($key) or die $box->ErrorStr;
    my $n_deleted = $box->Delete($key, \%options) or die $box->ErrorStr;
    warn "Nothing was deleted" unless int $n_deleted;
    
    my $deleted_tuple_set = $box->Delete($key, { want_deleted_tuples => 1 }) or die $box->ErrorStr;
    warn "Nothing was deleted" unless @$deleted_tuple_set;

=over

=item B<%options>

=over

=item B<space> => $space_id_uint32_or_name_string

Specify storage space (by id or name) to work on.

=item B<want_deleted_tuples> => $bool

if C<$bool> then return arrayref of deleted tuple(s).

=back

=back

=cut

sub Delete {
    my ($param, $namespace) = $_[0]->_validate_param(\@_, qw/want_deleted_tuples/);
    my ($self, $key) = @_;

    my $flags = 0;
    $flags |= WANT_RESULT if $param->{want_deleted_tuple};

    $self->_debug("$self->{name}: DELETE(NS:$namespace->{namespace},KEY:$key,F:$flags)") if $self->{debug} >= 3;

    confess "$self->{name}\->Delete: for now key cardinality of 1 is only allowed" unless 1 == @{$param->{index}->{keys}};
    $self->_pack_keys($namespace, $param->{index}, $key);

    $self->_chat(
        msg      => $flags ? 21 : 20,
        payload  => $flags ? pack("L L a*", $namespace->{namespace}, $flags, $key) : pack("L a*", $namespace->{namespace}, $key),
        unpack   => sub { $self->_unpack_affected($flags, $namespace, @_) },
        callback => $param->{callback},
    );
}

sub OP_SET          () { 0 }
sub OP_ADD          () { 1 }
sub OP_AND          () { 2 }
sub OP_XOR          () { 3 }
sub OP_OR           () { 4 }
sub OP_SPLICE       () { 5 }

my %update_ops = (
    set         => OP_SET,
    add         => OP_ADD,
    and         => OP_AND,
    xor         => OP_XOR,
    or          => OP_OR,
    splice      => sub {
        confess "value for operation splice must be an ARRAYREF of <int[, int[, string]]>" if ref $_[0] ne 'ARRAY' || @{$_[0]} < 1;
        $_[0]->[0] = 0x7FFFFFFF unless defined $_[0]->[0];
        $_[0]->[0] = pack 'l', $_[0]->[0];
        $_[0]->[1] = defined $_[0]->[1] ? pack 'l', $_[0]->[1] : '';
        $_[0]->[2] = '' unless defined $_[0]->[2];
        return (OP_SPLICE, [ pack '(w/a*)*', @{$_[0]} ]);
    },
    append      => sub { splice => [undef,  0,     $_[0]] },
    prepend     => sub { splice => [0,      0,     $_[0]] },
    cutbeg      => sub { splice => [0,      $_[0], ''   ] },
    cutend      => sub { splice => [-$_[0], $_[0], ''   ] },
    substr      => 'splice',
);

!ref $_ && m/^\D/ and $_ = $update_ops{$_} || die "bad link" for values %update_ops;

my %update_arg_fmt = (
    (map { $_ => 'l' } OP_ADD),
    (map { $_ => 'L' } OP_AND, OP_XOR, OP_OR),
);

my %ops_type = (
    (map { $_ => 'any'    } OP_SET),
    (map { $_ => 'number' } OP_ADD, OP_AND, OP_XOR, OP_OR),
    (map { $_ => 'string' } OP_SPLICE),
);

BEGIN {
    for my $op (qw/Append Prepend Cutbeg Cutend Substr/) {
        eval q/
            sub /.$op.q/ {
                my $param = ref $_[-1] eq 'HASH' ? pop : {};
                my ($self, $key, $field_num, $val) = @_;
                $self->UpdateMulti($key, [ $field_num => /.lc($op).q/ => $val ], $param);
            }
            1;
        / or die $@;
    }
}

=pod

=head3 Update

Update tuple in storage. Return false upon error.

    my $n_updated = $box->UpdateMulti($key, @op) or die $box->ErrorStr;
    my $n_updated = $box->UpdateMulti($key, @op, \%options) or die $box->ErrorStr;
    warn "Nothing was updated" unless int $n_deleted;
    
    my $updated_tuple_set = $box->UpdateMulti($key, @op, { want_result => 1 }) or die $box->ErrorStr;
    warn "Nothing was updated" unless @$updated_tuple_set;

=over

=item B<@op> = ([ $field_num => $op => $value ], ...)

=over

=item B<$field_num>

Field-to-update number.

=item B<$op>

=over

=item B<set>

Set C<< $field_num >> field to C<< $value >>

=item B<add>, B<and>, B<xor>, B<or>

Apply an arithmetic operation to C<< $field_num >> with argument C<< $value >>
Currently arithmetic operations are supported only for int32 (4-byte length) fields (and C<$value>s too)

=item B<splice>, B<substr>

Apply a perl-like L<splice> operation to C<< $field_num >>. B<$value> = [$OFFSET, $LENGTH, $REPLACE_WITH].
substr is just an alias.

=item B<append>, B<prepend>

Append or prepend C<< $field_num >> with C<$value> string.

=item B<cutbeg>, B<cutend>

Cut C<< $value >> bytes from beginning or end of C<< $field_num >>.

=back 

=back

=item B<%options>

=over

=item B<space> => $space_id_uint32_or_name_string

Specify storage space (by id or name) to work on.

=item B<want_result> => $bool

if C<$bool> then return arrayref of deleted tuple(s).

=back

=cut

sub UpdateMulti {
    my ($param, $namespace) = $_[0]->_validate_param(\@_, qw/want_result _flags/);
    my ($self, $key, @op) = @_;

    $self->_debug("$self->{name}: UPDATEMULTI(NS:$namespace->{namespace},KEY:$key)[@{[map{qq{[@$_]}}@op]}]") if $self->{debug} >= 3;

    confess "$self->{name}\->UpdateMulti: for now key cardinality of 1 is only allowed" unless 1 == @{$param->{index}->{keys}};
    confess "$self->{name}: too many op" if scalar @op > 128;

    my $flags = $param->{_flags} || 0;
    $flags |= WANT_RESULT if $param->{want_result};

    my $fmt = $namespace->{field_format};

    foreach (@op) {
        confess "$self->{name}: bad op <$_>" if ref ne 'ARRAY' or @$_ != 3;
        my ($field_num, $op, $value) = @$_;
        my $field_type = $namespace->{string_keys}->{$field_num} ? 'string' : 'number';

        my $is_array = 0;
        if ($op eq 'bit_set') {
            $op = OP_OR;
        } elsif ($op eq 'bit_clear') {
            $op = OP_AND;
            $value = ~$value;
        } elsif ($op =~ /^num_(add|sub)$/) {
            $value = -$value if $1 eq 'sub';
            $op = OP_ADD;
        } else {
            confess "$self->{name}: bad op <$op>" unless exists $update_ops{$op};
            $op = $update_ops{$op};
        }

        while(ref $op eq 'CODE') {
            ($op, $value) = &$op($value);
            $op = $update_ops{$op} if exists $update_ops{$op};
        }

        confess "Are you sure you want to apply `$ops_type{$op}' operation to $field_type field?" if $ops_type{$op} ne $field_type && $ops_type{$op} ne 'any';

        $value = [ $value ] unless ref $value;
        confess "dunno what to do with ref `$value'" if ref $value ne 'ARRAY';

        confess "bad fieldnum: $field_num" if $field_num >= @$fmt;
        $value = pack($update_arg_fmt{$op} || $fmt->[$field_num], @$value);
        $_ = pack('LCw/a*', $field_num, $op, $value);
    }

    $self->_pack_keys($namespace, $param->{index}, $key);

    $self->_chat(
        msg      => 19,
        payload  => pack("LL a* L (a*)*" , $namespace->{namespace}, $flags, $key, scalar(@op), @op),
        unpack   => sub { $self->_unpack_affected($flags, $namespace, @_) },
        callback => $param->{callback},
    );
}

sub Update {
    my $param = ref $_[-1] eq 'HASH' ? pop : {};
    my ($self, $key, $field_num, $value) = @_;
    $self->UpdateMulti($key, [$field_num => set => $value ], $param);
}

sub AndXorAdd {
    my $param = ref $_[-1] eq 'HASH' ? pop : {};
    my ($self, $key, $field_num, $and, $xor, $add) = @_;
    my @upd;
    push @upd, [$field_num => and => $and] if defined $and;
    push @upd, [$field_num => xor => $xor] if defined $xor;
    push @upd, [$field_num => add => $add] if defined $add;
    $self->UpdateMulti($key, @upd, $param);
}

sub Bit {
    my $param = ref $_[-1] eq 'HASH' ? pop : {};
    my ($self, $key, $field_num, %arg) = @_;
    confess "$self->{name}: unknown op '@{[keys %arg]}'"  if grep { not /^(bit_clear|bit_set|set)$/ } keys(%arg);

    $arg{bit_clear} ||= 0;
    $arg{bit_set}   ||= 0;
    my @op;
    push @op, [$field_num => set       => $arg{set}]        if exists $arg{set};
    push @op, [$field_num => bit_clear => $arg{bit_clear}]  if $arg{bit_clear};
    push @op, [$field_num => bit_set   => $arg{bit_set}]    if $arg{bit_set};

    $self->UpdateMulti($key, @op, $param);
}

sub Num {
    my $param = ref $_[-1] eq 'HASH' ? pop : {};
    my ($self, $key, $field_num, %arg) = @_;
    confess "$self->{name}: unknown op '@{[keys %arg]}'"  if grep { not /^(num_add|num_sub|set)$/ } keys(%arg);

    $arg{num_add} ||= 0;
    $arg{num_sub} ||= 0;

    $arg{num_add} -= $arg{num_sub};
    my @op;
    push @op, [$field_num => set     => $arg{set}]     if exists $arg{set};
    push @op, [$field_num => num_add => $arg{num_add}]; # if $arg{num_add};
    $self->UpdateMulti($key, @op, $param);
}

1;
