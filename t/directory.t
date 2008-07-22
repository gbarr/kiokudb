#!/usr/bin/perl

use strict;
use warnings;

use Test::More 'no_plan';
use Test::TempDir;
use Test::Memory::Cycle;

use Scalar::Util qw(blessed weaken isweak);

BEGIN { $MooseX::Storage::Directory::Resolver::SERIAL_IDS = 1 }

use ok 'MooseX::Storage::Directory';
use ok 'MooseX::Storage::Directory::Backend::JSPON';

my $dir = MooseX::Storage::Directory->new(
    backend => MooseX::Storage::Directory::Backend::JSPON->new(
        dir    => temp_root,
        pretty => 1,
        lock   => 0,
    ),
);

sub no_live_objects {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is_deeply(
        [ $dir->live_objects->live_objects ],
        [],
        "live object set is empty",
    );
}

{
    package Foo;
    use Moose;

    has foo => (
        isa => "Str",
        is  => "rw",
    );

    has bar => (
        is => "rw",
    );

    has parent => (
        is  => "rw",
        weak_ref => 1,
    );
}

# Pixie ain't got nuthin on us
my $id;

{
    my $x = Foo->new(
        foo => "dancing",
        bar => Foo->new(
            foo => "oh",
        ),
    );

    memory_cycle_ok($x, "no cycles in proto obj" );

    $x->bar->parent($x);

    memory_cycle_ok($x, "cycle is weak");

    $id = $dir->store($x);

    memory_cycle_ok($x, "store did not introduce cycles");

    is_deeply(
        [ sort $dir->live_objects->live_objects ],
        [ sort $x, $x->bar ],
        "live object set"
    );
};

no_live_objects;

{
    my $obj = $dir->lookup($id);

    is( $obj->foo, "dancing", "simple attr" );
    isa_ok( $obj->bar, "Foo", "object attr" );
    is( $obj->bar->foo, "oh", "simple attr of sub object" );
    isa_ok( $obj->bar->parent, "Foo", "object attr of sub object" );
    is( $obj->bar->parent, $obj, "circular ref" );
}

no_live_objects;

{
    my $x = Foo->new(
        foo => "oink oink",
        bar => my $y = Foo->new(
            foo => "yay",
        ),
    );

    my @ids = $dir->store($x, $y);

    is( scalar(@ids), 2, "got two ids" );

    undef $x;

    is( $dir->live_objects->id_to_object($ids[0]), undef, "first object is dead" );
    is( $dir->live_objects->id_to_object($ids[1]), $y, "second is still alive" );

    my @objects = map { $dir->lookup($_) } @ids;
    
    isa_ok( $objects[0], "Foo" );
    is( $objects[0]->foo, "oink oink", "object retrieved" );
    is( $objects[1], $y, "object is already live" );
    is( $objects[0]->bar, $y, "link recreated" );
}

no_live_objects;

{

    $dir->linker->lazy(1);

    my $obj = $dir->lookup($id);

    is( scalar($dir->live_objects->live_objects), 1, "only one thunk loaded so far" );

    is( blessed($obj), "Data::Thunk::Object", "it's actually a thunk" );

    isa_ok( $obj, "Foo" ); 
    is( $obj->foo, "dancing", "field works" );

    is( blessed($obj), "Foo", "thunk upgraded to object" );

    is( scalar($dir->live_objects->live_objects), 2, "two objects loaded" );

    is( $obj->bar->parent, $obj, "circular ref still correct even when lazy" );
}

no_live_objects;

{
    $dir->linker->lazy(0);

    my @ids = do{
        my $shared = Foo->new( foo => "shared" );

        my $first  = Foo->new( foo => "first",  bar => $shared );
        my $second = Foo->new( foo => "second", bar => $shared );

        $dir->store( $first, $second );
    };

    no_live_objects;

    my $first = $dir->lookup($ids[0]);

    isa_ok( $first, "Foo" );
    is( $first->foo, "first", "normal attr" );
    isa_ok( $first->bar, "Foo", "shared object" );
    is( $first->bar->foo, "shared", "normal attr of shared" );
    
    my $second = $dir->lookup($ids[1]);

    isa_ok( $second, "Foo" );
    is( $second->foo, "second", "normal attr" );

    is( $second->bar, $first->bar, "shared object" );
}

no_live_objects;

{
    $dir->linker->lazy(0);

    my @ids = do{
        my $shared = { foo => "shared", object => Foo->new( foo => "shared child" ) };

        $shared->{object}->parent($shared);

        my $first  = Foo->new( foo => "first",  bar => $shared );
        my $second = Foo->new( foo => "second", bar => $shared );

        $dir->store( $first, $second );
    };

    no_live_objects;

    my $first = $dir->lookup($ids[0]);

    isa_ok( $first, "Foo" );
    is( $first->foo, "first", "normal attr" );

    is( ref($first->bar), "HASH", "shared hash" );
    is( $first->bar->{foo}, "shared", "hash data" );

    isa_ok( $first->bar->{object}, "Foo", "indirect shared child" );
    
    my $second = $dir->lookup($ids[1]);

    isa_ok( $second, "Foo" );
    is( $second->foo, "second", "normal attr" );

    is( $second->bar, $first->bar, "shared value" );
}

no_live_objects;

{
    $dir->linker->lazy(0);

    my $id = do{
        my $shared = { foo => "hippies" };

        weaken($shared->{self} = $shared);

        $dir->store( Foo->new( foo => "blimey", bar => $shared ) );
    };

    no_live_objects;

    my $obj = $dir->lookup($id);

    isa_ok( $obj, "Foo" );
    is( $obj->foo, "blimey", "normal attr" );

    is( ref($obj->bar), "HASH", "shared hash" );
    is( $obj->bar->{foo}, "hippies", "hash data" );
    is( $obj->bar->{self}, $obj->bar, "circular ref" );

    {
        local $TODO = "weaken is not yet supported in expander";
        ok( isweak($obj->bar->{self}), "weak ref" );

        weaken($obj->bar->{self}); # to make no_live_objects pass
    }
}

no_live_objects;
