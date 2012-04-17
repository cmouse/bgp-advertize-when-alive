#!/usr/bin/perl

use warnings;
use strict;
use 5.005;
use Net::BGP::Process;
use Net::BGP::Peer;
use Proc::Daemon;
use Proc::PID::File;
use Carp::Clan;
use Data::Dumper;
use Net::BGP::Update;
use Sys::Syslog qw(:standard :macros); 
use File::Basename;

my $background = 0;

my $peers = [
		{
			'local_ip' => '',
			'local_as' => 0,
			'remote_ip' => '',
			'remote_as' => 0,
			'prefixes' => [
				{
					'name' => 'Test server',
					'prefixes' => ['127.0.0.1/32'],
					'destination' => '127.0.0.2',
					'check' => './buggy.pl',
					'med' => 100,
					'localpref' => 100,
					'communities' => [],
					'state' => 0
				},
			]
             }
];

my $errors = {
	1 => { 
		1 => 'Connection Not Syncronized',
		2 => 'Bad Message Length',
		3 => 'Bad Message Type'
	}, 
	2 => {
		1 => 'Unsupported Version',
		2 => 'Bad Peer AS',
		3 => 'Bad Peer Identifier',
		4 => 'Unsupported Optional Parameter',
		5 => 'Authentication Failure',
		6 => 'Unacceptable Hold Time'
	},
	3 => {
		1 => 'Malformed Attribute List',
		2 => 'Unrecognized well-known attribute',	
		3 => 'Missing Well-Known Attribute',
		4 => 'Attribute Flags Error',
		5 => 'Attribute Length Error',
		6 => 'Invalid Origin Attribute',
		7 => 'AS routing loop',
		8 => 'Invalid NEXT_HOP attribute',
		9 => 'Optional Attribute Error',
		10 => 'Invalid Network Field',
		11 => 'Malformed AS_Path'
 	},
	4 => 'Hold Timer Expired',
	5 => 'Finite State Error',
	6 => 'Cease'
};

sub cleanup_peer_blocks {
	my ($peer) = @_;
	
	for my $obj (@$peers) {
		if ($obj->{remote_ip} eq $peer) {
			for my $block (@{$obj->{prefixes}}) {
				$block->{state} = 0;
			}
		}
	}
}

sub notification_to_text {
	my ($code, $subcode) = @_;
	
	if (ref $errors->{$code} eq 'HASH') {
		return $errors->{$code}->{$subcode} if (defined $errors->{$code}->{$subcode});
	} elsif (defined $errors->{$code}) {
		return $errors->{$code};
	}
	return "UNKNOWN NOTIFICATION $code:$subcode";
}
		
sub my_log {
	my $prio = shift;
	my $format = shift;
	syslog $prio, $format, @_;
}

sub my_open_callback {
	my ($peer) = @_;
	my_log LOG_INFO, "Connected to %s", $peer->peer_id();
}

sub my_notification_callback {
        my ($peer, $error) = @_;
	my_log LOG_ERR, "Notification: %s - reconnecting", notification_to_text($error->error_code(), $error->error_subcode());
	# always reconnect on error
	cleanup_peer_blocks $peer->peer_id();
}

sub my_error_callback {
        my ($peer, $error) = @_;
	my_log LOG_ERR, "Notification: %s - reconnecting", notification_to_text($error->error_code(), $error->error_subcode());
        cleanup_peer_blocks $peer->peer_id();
}

sub process_peer {
	my $peer = shift;
	my $obj = shift;

	# perform check, if fails, withdraw routes

	if (!$peer->is_established()) {
			my_log LOG_INFO, "Attempting to (re)connect %s", $peer->peer_id();
			# clear blocks
			cleanup_peer_blocks $peer->peer_id();
			$peer->start();
			return;
	}
	
	for my $block (@{$obj->{prefixes}}) {
		qx($block->{check});
                my $nets = $block->{prefixes};

		if ($? == 0) {
			# advertise prefixes
			if ($block->{state} == 0) {
	                        my_log LOG_INFO, "%s is now ok - advertising %d network(s)", $block->{name}, scalar(@$nets);
				my $update = Net::BGP::Update->new(
        				NLRI            => [ @$nets ],
				        LocalPref       => $block->{localpref},
					AsPath          => $obj->{local_as},
				        MED             => $block->{med},
					Communities	=> $block->{communities},
				        NextHop         => $block->{destination},
				        Origin          => Net::BGP::Update::IGP
	           		);
				$peer->update($update);
				$block->{state} = 1;
			}
		} else {
			if ($block->{state} == 1) {
				my_log LOG_INFO, "%s is no longer ok - withdrawing %d network(s)", $block->{name}, scalar(@$nets);
				my $nets = $block->{prefixes};
				my $update = Net::BGP::Update->new(
					Withdraw        => [ @$nets ],
				);
				$peer->update($update);
				$block->{state} = 0;
			}
		}
	}
} 

sub my_timer_callback {
	my $peer = shift;

	for my $obj (@$peers) {
		if ($obj->{remote_ip} eq $peer->peer_id()) {
			process_peer $peer, $obj;
		}
	}
}

sub main {
	croak "Must be ran as root" if $< != 0;

	if ($background) {
		croak "Already running!" if Proc::PID::File->running();
		Proc::Daemon::Init;
		openlog basename($0), 'pid', 'daemon';
	} else {
		openlog basename($0), 'perror,pid', 'daemon';
	}

	my_log LOG_INFO,"Simple BGP Daemon v0.1 (c) Aki Tuomi 2012 started";

	my $bgp  = Net::BGP::Process->new();

	# build peers

	for my $obj (@$peers) {
		my $peer = Net::BGP::Peer->new(
	               Start    => 1,
        	       ThisID   => $obj->{local_ip},
	               ThisAS   => $obj->{local_as},
	               PeerID   => $obj->{remote_ip},
	               PeerAS   => $obj->{remote_as},
	               OpenCallback         => \&my_open_callback,
	               NotificationCallback => \&my_notification_callback,
        	       ErrorCallback        => \&my_error_callback
		);

		$obj->{peer} = $peer;
		$bgp->add_peer($obj->{peer});
	        $peer->add_timer(\&my_timer_callback, 10);
	}

	$bgp->event_loop();
}

main;
