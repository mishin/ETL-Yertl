package ETL::Yertl::Command::ysql;
# ABSTRACT: Read and write documents with a SQL database

use ETL::Yertl;
use Getopt::Long qw( GetOptionsFromArray :config pass_through );
use ETL::Yertl::Format::yaml;
use File::HomeDir;

sub main {
    my $class = shift;

    eval { require DBI; };
    if ( $@ ) {
        die "Can't load ysql: Can't load DBI. Make sure the DBI module is installed.\n";
    }

    my %opt;
    if ( ref $_[-1] eq 'HASH' ) {
        %opt = %{ pop @_ };
    }

    my @args = @_;
    GetOptionsFromArray( \@args, \%opt,
        'config',
        'drivers',
        'driver|t=s',
        'database|db=s',
        'host|h=s',
        'port|p=s',
        'user|u=s',
        'password|pass=s',
        'save=s',
    );
    #; use Data::Dumper;
    #; say Dumper \@args;
    #; say Dumper \%opt;

    my $out_fmt = ETL::Yertl::Format::yaml->new;

    if ( $opt{config} ) {
        my $db_key = shift @args;

        if ( !$db_key ) {
            my $out_fmt = ETL::Yertl::Format::yaml->new;
            print $out_fmt->write( config() );
            return 0;
        }

        # Get the existing config first
        my $db_conf = db_config( $db_key );

        if ( !@args && !grep { defined } @opt{qw( dsn driver database host port user password )} ) {
            die "Database key '$db_key' does not exist" unless keys %$db_conf;
            my $out_fmt = ETL::Yertl::Format::yaml->new;
            print $out_fmt->write( $db_conf );
            return 0;
        }

        #; use Data::Dumper;
        #; say "Got from options: " . Dumper $db_conf;
        #; say "Left in \@args: " . Dumper \@args;

        for my $key ( qw{ driver database host port user password } ) {
            next if !$opt{ $key };
            $db_conf->{ $key } = $opt{ $key };
        }

        # Set via DSN
        if ( my $dsn = $opt{dsn} || shift( @args ) ) {
            delete $db_conf->{ $_ } for qw( driver database host port );
            my ( undef, $driver, undef, undef, $driver_dsn ) = DBI->parse_dsn( $dsn );
            $db_conf->{ driver } = $driver;

            # The driver_dsn part is up to the driver, but we can make some guesses
            if ( $driver_dsn !~ /[=:;@]/ ) {
                $db_conf->{ database } = $driver_dsn;
            }
            elsif ( $driver_dsn =~ /^(\w+)\@([\w.]+)(?:\:(\d+))?$/ ) {
                $db_conf->{ database } = $1;
                $db_conf->{ host } = $2;
                $db_conf->{ port } = $3;
            }
            elsif ( my @parts = split /\;/, $driver_dsn ) {
                for my $part ( @parts ) {
                    my ( $part_key, $part_value ) = split /=/, $part;
                    if ( $part_key eq 'dbname' ) {
                        $part_key = 'database';
                    }
                    $db_conf->{ $part_key } = $part_value;
                }
            }
            else {
                die "Unknown driver DSN: $driver_dsn";
            }
        }

        # Check if the driver is installed
        my $driver = $db_conf->{driver};
        if ( !grep { /^$driver$/ } DBI->available_drivers ) {
            my @possible = grep { /^$driver$/i } DBI->available_drivers;
            my $suggest = @possible ? " Did you mean: $possible[0]" : '';
            warn "Driver '$driver' does not exist." . $suggest . "\n";
        }

        # Write back the config
        db_config( $db_key => $db_conf );

    }
    elsif ( $opt{drivers} ) {
        my $ignore = join "|", qw( ExampleP Sponge File );
        say join "\n", grep { !/^(?:$ignore)$/ } DBI->available_drivers;

    }
    else {
        if ( $opt{ save } ) {
            my $db_key = shift @args;
            my $db_conf = db_config( $db_key );
            $db_conf->{query}{ $opt{save} } = shift @args;
            db_config( $db_key => $db_conf );
            return 0;
        }

        my $db_key = !$opt{dsn} ? shift @args : undef;
        if ( !$db_key && !$opt{dsn} ) {
            die "Must specify a database!\n";
        }

        my @dbi_args = $opt{dsn} ? ( $opt{dsn} ) : dbi_args( $db_key );
        if ( !@dbi_args ) {
            die "Unknown database '$db_key'\n";
        }

        my $dbh = DBI->connect( @dbi_args, { PrintError => 0 } );

        my $query = shift @args;
        if ( $db_key ) {
            my $db_conf = db_config( $db_key );
            if ( $db_conf->{query}{ $query } ) {
                $query = $db_conf->{query}{ $query };
            }
        }

        # Resolve interpolations with placeholders
        my @fields = $query =~ m/\$(\.[.\w]+)/g;
        $query =~ s/\$\.[\w.]+/?/g;

        my $sth = $dbh->prepare( $query )
            or die "SQL error in prepare: " . $dbh->errstr . "\n";

        if ( !-t *STDIN ) {
            my $in_fmt = ETL::Yertl::Format::yaml->new( input => \*STDIN );

            for my $doc ( $in_fmt->read ) {
                $sth->execute( map { select_doc( $_, $doc ) } @fields )
                    or die "SQL error in execute: " . $dbh->errstr . "\n";
                while ( my $doc = $sth->fetchrow_hashref ) {
                    print $out_fmt->write( $doc );
                }
            }

        }
        else {
            $sth->execute( @args )
                or die "SQL error in execute: " . $dbh->errstr . "\n";
            while ( my $doc = $sth->fetchrow_hashref ) {
                print $out_fmt->write( $doc );
            }
        }

        return 0;
    }
}

sub config {
    my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
    my $config = {};
    if ( $conf_file->exists ) {
        my $yaml = ETL::Yertl::Format::yaml->new( input => $conf_file->openr );
        ( $config ) = $yaml->read;
    }
    return $config;
}

sub db_config {
    my ( $db_key, $config ) = @_;
    if ( $config ) {
        my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
        if ( !$conf_file->exists ) {
            $conf_file->touchpath;
        }
        my $all_config = config();
        $all_config->{ $db_key } = $config;
        my $yaml = ETL::Yertl::Format::yaml->new;
        $conf_file->spew( $yaml->write( $all_config ) );
        return;
    }
    return config()->{ $db_key } || {};
}

sub select_doc {
    my ( $select, $doc ) = @_;
    $select =~ s/^[.]//; # select must start with .
    my @parts = split /[.]/, $select;
    for my $part ( @parts ) {
        $doc = $doc->{ $part };
    }
    return $doc;
}

sub dbi_args {
    my ( $db_name ) = @_;
    my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
    if ( $conf_file->exists ) {
        my $yaml = ETL::Yertl::Format::yaml->new( input => $conf_file->openr );
        my ( $config ) = $yaml->read;
        my $db_config = $config->{ $db_name };

        my $driver_dsn =
            join ";",
            map { join "=", $_, $db_config->{ $_ } }
            grep { $db_config->{ $_ } }
            qw( database host port )
            ;

        return (
            sprintf( 'dbi:%s:%s', $db_config->{driver}, $driver_dsn ),
            $db_config->{user},
            $db_config->{password},
        );
    }
}

1;
__END__

