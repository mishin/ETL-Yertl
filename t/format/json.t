
use ETL::Yertl 'Test';
use Test::Lib;
use ETL::Yertl::Format::json;
my $SHARE_DIR = path( __DIR__, '..', 'share' );

my $CLASS = 'ETL::Yertl::Format::json';

# 3-space indents because JSON::XS provides no other option
my $EXPECT_TO = $SHARE_DIR->child( json => 'test.json' );

my @EXPECT_FROM = (
    {
        foo => 'bar',
        baz => 'buzz',
    },
    {
        flip => [qw( flop blip )],
    },
    [qw( foo bar baz )],
);

subtest 'constructor' => sub {
    subtest 'invalid format module' => sub {
        throws_ok {
            $CLASS->new( format_module => 'Not::Supported' );
        } qr{format_module must be one of: JSON::XS JSON::PP};
    };
};

subtest 'default formatter' => sub {
    subtest 'input' => sub {
        my $formatter = $CLASS->new(
            input => $EXPECT_TO->openr,
        );
        my $got = [ $formatter->read ];
        cmp_deeply $got, \@EXPECT_FROM or diag explain $got;
    };

    subtest 'output' => sub {
        my $formatter = $CLASS->new;
        eq_or_diff $formatter->write( @EXPECT_FROM ), $EXPECT_TO->slurp;
    };
};

subtest 'formatter modules' => sub {
    subtest 'JSON::XS' => sub {
        subtest 'input' => sub {
            my $formatter = $CLASS->new(
                input => $EXPECT_TO->openr,
                format_module => 'JSON::XS',
            );
            my $got = [ $formatter->read ];
            cmp_deeply $got, \@EXPECT_FROM or diag explain $got;
        };

        subtest 'output' => sub {
            my $formatter = $CLASS->new( format_module => 'JSON::XS' );
            eq_or_diff $formatter->write( @EXPECT_FROM ), $EXPECT_TO->slurp;
        };
    };

    subtest 'JSON::PP' => sub {
        subtest 'input' => sub {
            my $formatter = $CLASS->new(
                input => $EXPECT_TO->openr,
                format_module => 'JSON::PP',
            );
            my $got = [ $formatter->read ];
            cmp_deeply $got, \@EXPECT_FROM or diag explain $got;
        };

        subtest 'output' => sub {
            my $formatter = $CLASS->new( format_module => 'JSON::PP' );
            eq_or_diff $formatter->write( @EXPECT_FROM ), $EXPECT_TO->slurp;
        };
    };
};

subtest 'no formatter available' => sub {
    local @ETL::Yertl::Format::json::FORMAT_MODULES = (
        'Not::JSON::Module' => 0,
        'Not::Other::Module' => 0,
        'LowVersion' => 1,
    );
    throws_ok {
        $CLASS->new->format_module;
    } qr{Could not load a formatter for JSON[.] Please install one of the following modules:};
    like $@, qr{Not::JSON::Module \(Any version\)};
    like $@, qr{Not::Other::Module \(Any version\)};
    like $@, qr{LowVersion \(version 1\)};
};

done_testing;
