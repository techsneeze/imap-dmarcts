#!/usr/bin/perl

################################################################################
# dmarcts-report-parser - A Perl based tool to parse DMARC reports from an IMAP
# mailbox or from the filesystem, and insert the information into a database.
# ( Formerly known as imap-dmarcts )
#
# Copyright (C) 2016 TechSneeze.com and John Bieling
#
# Available at:
# https://github.com/techsneeze/dmarcts-report-parser
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of  MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
################################################################################

################################################################################
# The subroutines storeXMLInDatabase() and getXMLFromMessage() are based on
# John R. Levine's rddmarc (http://www.taugh.com/rddmarc/). The following
# special conditions apply to those subroutines:
#
# Copyright 2012, Taughannock Networks. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or
# other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
################################################################################

# Always be safe
use strict;
use warnings;

# Use these modules
use Getopt::Long;
use IO::Compress::Gzip qw(gzip $GzipError);
#use Data::Dumper;
use Mail::IMAPClient;
use Mail::Mbox::MessageParser;
use MIME::Base64 qw(encode_base64);
use MIME::Words qw(decode_mimewords);
use MIME::Parser;
use MIME::Parser::Filer;
use XML::Simple;
use DBI;
use Socket;
use Socket6;
use PerlIO::gzip;
use File::Basename ();
use File::MimeInfo;
use IO::Socket::SSL;
#use IO::Socket::SSL 'debug3';



################################################################################
### usage ######################################################################
################################################################################

sub show_usage {
	print "\n";
	print " Usage: \n";
	print "    ./dmarcts-report-parser.pl [OPTIONS] [PATH] \n";
	print "\n";
	print " This script needs a configuration file called <dmarcts-report-parser.conf> in \n";
	print " the current working directory, which defines a database server with credentials \n";
	print " and (if used) an IMAP server with credentials. \n";
	print "\n";
	print " Additionaly, one of the following source options must be provided: \n";
	print "        -i : Read reports from messages on IMAP server as defined in the \n";
	print "             config file. \n";
	print "        -m : Read reports from mbox file(s) provided in PATH. \n";
	print "        -e : Read reports from MIME email file(s) provided in PATH. \n";
	print "        -x : Read reports from xml file(s) provided in PATH. \n";
	print "        -z : Read reports from zip file(s) provided in PATH. \n";
	print "\n";
	print " The following optional options are allowed: \n";
	print "        -d : Print debug info. \n";
	print "        -r : Replace existing reports rather than skipping them. \n";
	print "  --delete : Delete processed message files (the XML is stored in the \n";
	print "             database for later reference). \n";
	print "    --info : Print out number of XML files or emails processed. \n";
	print "\n";
}





################################################################################
### main #######################################################################
################################################################################

# Define all possible configuration options.
our ($debug, $delete_reports, $delete_failed, $reports_replace, $maxsize_xml, $compress_xml,
	$dbname, $dbuser, $dbpass, $dbhost, $dbport, $db_tx_support,
  $imapserver, $imapport, $imapuser, $imappass, $imapignoreerror, $imapssl, $imaptls, $imapmovefolder,
	$imapmovefoldererr, $imapreadfolder, $imapopt, $tlsverify, $processInfo);

# defaults
$maxsize_xml 	= 50000;
$db_tx_support	= 1;

# used in messages
my $scriptname = 'dmarcts-report-parser.pl';

# allowed values for the DB columns, also used to build the enum() in the
# CREATE TABLE statements in checkDatabase(), in order defined here
use constant ALLOWED_DISPOSITION => qw(
	none
	quarantine
	reject
	unknown
);
use constant ALLOWED_DKIM_ALIGN => qw(
	fail
	pass
	unknown
);
use constant ALLOWED_SPF_ALIGN => qw(
	fail
	pass
	unknown
);
use constant ALLOWED_DKIMRESULT => qw(
	none
	pass
	fail
	neutral
	policy
	temperror
	permerror
	unknown
);
use constant ALLOWED_SPFRESULT => qw(
	none
	neutral
	pass
	fail
	softfail
	temperror
	permerror
	unknown
);

# Load script configuration options from local config file. The file is expected
# to be in the current working directory.
my $conf_file = 'dmarcts-report-parser.conf';

# Get command line options.
my %options = ();
use constant { TS_IMAP => 0, TS_MESSAGE_FILE => 1, TS_XML_FILE => 2, TS_MBOX_FILE => 3, TS_ZIP_FILE => 4 };
GetOptions( \%options, 'd', 'r', 'x', 'm', 'e', 'i', 'z', 'delete', 'info', 'c' => \$conf_file );

# locate conf file or die
if ( -e $conf_file ) {
  #$conf_file = "./$conf_file";
} elsif( -e  (File::Basename::dirname($0) . "/$conf_file" ) ) {
	$conf_file = ( File::Basename::dirname($0) . "/$conf_file" );
} else {
	show_usage();
	die "$scriptname: Could not read config file '$conf_file' from current working directory or path (" . File::Basename::dirname($0) . ')'
}

# load conf file with error handling
if ( substr($conf_file, 0, 1) ne '/'  and substr($conf_file, 0, 1) ne '.') {
  $conf_file = "./$conf_file";
}
my $conf_return = do $conf_file;
die "$scriptname: couldn't parse $conf_file: $@" if $@;
die "$scriptname: couldn't do $conf_file: $!"    unless defined $conf_return;

# check config
if (!defined $imapreadfolder ) {
  die "$scriptname: \$imapreadfolder not defined. Check config file";
}
if (!defined $imapignoreerror ) {
  $imapignoreerror = 0;   # maintain compatibility to old version
}

# Evaluate command line options
my $source_options = 0;
our $reports_source;

if (exists $options{m}) {
	$source_options++;
	$reports_source = TS_MBOX_FILE;
}

if (exists $options{x}) {
	$source_options++;
	$reports_source = TS_XML_FILE;
}

if (exists $options{e}) {
	$source_options++;
	$reports_source = TS_MESSAGE_FILE;
}

if (exists $options{i}) {
	$source_options++;
	$reports_source = TS_IMAP;
}

if (exists $options{z}) {
	$source_options++;
	$reports_source = TS_ZIP_FILE;
}

if (exists $options{c}) {
	$source_options++;
}

if ($source_options > 1) {
	show_usage();
	die "$scriptname: Only one source option can be used (-i, -x, -m, -e or -z).\n";
} elsif ($source_options == 0) {
	show_usage();
	die "$scriptname: Please provide a source option (-i, -x, -m, -e or -z).\n";
}

if ($ARGV[0]) {
	if ($reports_source == TS_IMAP) {
		show_usage();
		die "$scriptname: The IMAP source option (-i) may not be used together with a PATH.\n";
	}
} else {
	if ($reports_source != TS_IMAP && $source_options == 1) {
		show_usage();
		die "$scriptname: The provided source option requires a PATH.\n";
	}
}

# Override config options by command line options.
if (exists $options{r}) {$reports_replace = 1;}
if (exists $options{d}) {$debug = 1;}
if (exists $options{delete}) {$delete_reports = 1;}
if (exists $options{info}) {$processInfo = 1;}

# Setup connection to database server.
my $dbh = DBI->connect("DBI:mysql:database=$dbname;host=$dbhost;port=$dbport",
	$dbuser, $dbpass)
or die "$scriptname: Cannot connect to database\n";
checkDatabase($dbh);


# Process messages based on $reports_source.
if ($reports_source == TS_IMAP) {
	my $socketargs = '';
	my $processedReport = 0;

	# Disable verify mode for TLS support.
	if ($imaptls == 1) {
		if ( $tlsverify == 0 ) {
			print "use tls without verify servercert.\n" if $debug;
			$imapopt = [ SSL_verify_mode => SSL_VERIFY_NONE ];
		} else {
			print "use tls with verify servercert.\n" if $debug;
			$imapopt = [ SSL_verify_mode => SSL_VERIFY_PEER ];
		}
	# The whole point of setting this socket arg is so that we don't get the nasty warning
	} else {
		if ( $tlsverify == 0 ) {
			print "use tls without verify servercert.\n" if $debug;
			$socketargs = [ SSL_verify_mode => SSL_VERIFY_NONE ];
		} else {
			print "use tls with verify servercert.\n" if $debug;
			$socketargs = [ SSL_verify_mode => SSL_VERIFY_PEER ];
		}
	}
  
	print "connection to $imapserver with Ssl => $imapssl, User => $imapuser, Ignoresizeerrors => $imapignoreerror\n" if $debug;

	# Setup connection to IMAP server.
	my $imap = Mail::IMAPClient->new(
	  Server     => $imapserver,
	  Port       => $imapport,
	  Ssl        => $imapssl,
	  Starttls   => $imapopt,
	  Debug      => $debug,
	  Socketargs => $socketargs
	)
	# module uses eval, so we use $@ instead of $!
	or die "$scriptname: IMAP Failure: $@";

	# This connection is finished this way because of the tradgedy of exchange...
	$imap->User($imapuser);
	$imap->Password($imappass);
	$imap->connect();

	# Ignore Size Errors if we're using Exchange
	$imap->Ignoresizeerrors($imapignoreerror);

	# Set $imap to UID mode, which will force imap functions to use/return
	# UIDs, instead of message sequence numbers. UIDs are not allowed to
	# change during a session and are not allowed to be used twice. Looping
	# over message sequence numbers and deleting a msg in between could have
	# unwanted side effects.
	$imap->Uid(1);

	# How many msgs are we going to process?
	print "Processing ". $imap->message_count($imapreadfolder)." messages in folder <$imapreadfolder>.\n" if $debug;

	# Only select and search $imapreadfolder, if we actually
	# have something to do.
	if ($imap->message_count($imapreadfolder)) {
		# Select the mailbox to get messages from.
		$imap->select($imapreadfolder)
			or die "$scriptname: IMAP Select Error: $!";

		# Store each message as an array element.
		my @msgs = $imap->search('ALL')
			or die "$scriptname: Couldn't get all messages\n";

		# Loop through IMAP messages.
		foreach my $msg (@msgs) {

			my $processResult = processXML(TS_MESSAGE_FILE, $imap->message_string($msg), "IMAP message with UID #".$msg);
			$processedReport++;
			if ($processResult & 4) {
				# processXML returned a value with database error bit enabled, do nothing at all!
				if ($imapmovefoldererr) {
					# if we can, move to error folder
					moveToImapFolder($imap, $msg, $imapmovefoldererr);
				} else {
					# do nothing at all
					next;
				}
			} elsif ($processResult & 2) {
				# processXML return a value with delete bit enabled.
				$imap->delete_message($msg)
				or warn "$scriptname: Could not delete IMAP message. [$@]\n";
			} elsif ($imapmovefolder) {
				if ($processResult & 1 || !$imapmovefoldererr) {
					# processXML processed the XML OK, or it failed and there is no error imap folder
					moveToImapFolder($imap, $msg, $imapmovefolder);
				} elsif ($imapmovefoldererr) {
					# processXML failed and error folder set
					moveToImapFolder($imap, $msg, $imapmovefoldererr);
				}
			} elsif ($imapmovefoldererr && !($processResult & 1)) {
				# processXML failed, error imap folder set, but imapmovefolder unset. An unlikely setup, but still...
				moveToImapFolder($imap, $msg, $imapmovefoldererr);
			}
		}

		# Expunge and close the folder.
		$imap->expunge($imapreadfolder);
		$imap->close($imapreadfolder);
	}

	# We're all done with IMAP here.
	$imap->logout();
	if ( $debug || $processInfo ) { print "$scriptname: Processed $processedReport emails.\n"; }

} else { # TS_MESSAGE_FILE or TS_XML_FILE or TS_MBOX_FILE

	my $counts = 0;
	foreach my $a (@ARGV) {
		# Linux bash supports wildcard expansion BEFORE the script is
		# called, so here we only see a list of files. Other OS behave
		# different, so we should not depend on that feature: Use glob
		# on each argument to manually expand the argument, if possible.
		my @file_list = glob($a);

		foreach my $f (@file_list) {
			my $filecontent;

			if ($reports_source == TS_MBOX_FILE) {
				my $parser = Mail::Mbox::MessageParser->new({"file_name" => $f, "debug" => $debug, "enable_cache" => 0});
				my $num = 0;

				do {
					$num++;
					$filecontent = $parser->read_next_email();
					if (defined($filecontent)) {
						if (processXML(TS_MESSAGE_FILE, $filecontent, "message #$num of mbox file <$f>") & 2) {
							# processXML return a value with delete bit enabled
							warn "$scriptname: Removing message #$num from mbox file <$f> is not yet supported.\n";
						}
						$counts++;
					}
				} while(defined($filecontent));

			} elsif ($reports_source == TS_ZIP_FILE) {
				# filecontent is zip file
				$filecontent = getXMLFromZip($f);
				if (processXML(TS_ZIP_FILE, $filecontent, "xml file <$f>") & 2) {
					# processXML return a value with delete bit enabled
					unlink($f);
				}
				$counts++;
			} elsif (open(FILE, "<", $f)) {

				$filecontent = join("", <FILE>);
				close FILE;

				if ($reports_source == TS_MESSAGE_FILE) {
					# filecontent is a mime message with zip or xml part
					if (processXML(TS_MESSAGE_FILE, $filecontent, "message file <$f>") & 2) {
						# processXML return a value with delete bit enabled
						unlink($f);
					}
					$counts++;
				} elsif ($reports_source == TS_XML_FILE) {
					# filecontent is xml file
					if (processXML(TS_XML_FILE, $filecontent, "xml file <$f>") & 2) {
						# processXML return a value with delete bit enabled
						unlink($f);
					}
					$counts++;
				} else {
					warn "$scriptname: Unknown reports_source <$reports_source> for file <$f>. Skipped.\n";
				}

			} else {
				warn "$scriptname: Could not open file <$f>: $!. Skipped.\n";
				# Could not retrieve filecontent, the skipped message
				# will be processed every time the script is run even if
				# delete_reports and delete_failed is given. The user
				# has to look at the actual file.
			}
		}
	}
	if ($debug || $processInfo) { print "$scriptname: Processed $counts messages(s).\n"; }
}



################################################################################
### subroutines ################################################################
################################################################################

sub moveToImapFolder {
	my $imap = $_[0];
	my $msg = $_[1];
	my $imapfolder = $_[2];

	print "Moving (copy and delete) IMAP message file to IMAP folder: $imapfolder\n" if $debug;

	# Try to create $imapfolder, if it does not exist.
	if (!$imap->exists($imapfolder)) {
		$imap->create($imapfolder)
		or warn "$scriptname: Could not create IMAP folder: $imapfolder.\n";
	}

	# Try to move the message to $imapfolder.
	my $newid = $imap->copy($imapfolder, [ $msg ]);
	if (!$newid) {
		warn "$scriptname: Error on moving (copy and delete) processed IMAP message: Could not COPY message to IMAP folder: <$imapfolder>!\n";
		warn "$scriptname: Messsage will not be moved/deleted. [$@]\n";
	} else {
		$imap->delete_message($msg)
		or do {
			warn "$scriptname: Error on moving (copy and delete) processed IMAP message: Could not DELETE message\n";
			warn "$scriptname: after copying it to <$imapfolder>. [$@]\n";
		}
	}
}

sub processXML {
	my ($type, $filecontent, $f) = (@_);

	if ($debug) {
		print "\n";
		print "----------------------------------------------------------------\n";
		print "Processing $f \n";
		print "----------------------------------------------------------------\n";
		print "Type: $type\n";
		print "FileContent: $filecontent\n";
		print "MSG: $f\n";
		print "----------------------------------------------------------------\n";
	}

	my $xml; #TS_XML_FILE or TS_MESSAGE_FILE
	if ($type == TS_MESSAGE_FILE) {$xml = getXMLFromMessage($filecontent);}
	elsif ($type == TS_ZIP_FILE) {$xml = $filecontent;}
	else {$xml = getXMLFromXMLString($filecontent);}

	# If !$xml, the file/mail is probably not a DMARC report.
	# So do not storeXMLInDatabase.
	if ($xml && storeXMLInDatabase($xml) <= 0) {
		# If storeXMLInDatabase returns false, there was some sort
		# of database storage failure and we MUST NOT delete the
		# file, because it has not been pushed into the database.
		# The user must investigate this issue.
		warn "$scriptname: Skipping $f due to database errors.\n";
		return 5; #xml ok(1), but database error(4), thus no delete (!2)
	}

	# Delete processed message, if the --delete option
	# is given. Failed reports are only deleted, if delete_failed is given.
	if ($delete_reports && ($xml || $delete_failed)) {
		if ($xml) {
			print "Removing after report has been processed.\n" if $debug;
			return 3; #xml ok (1), delete file (2)
		} else {
			# A mail which does not look like a DMARC report
			# has been processed and should now be deleted.
			# Print its content so it gets send as cron
			# message, so the user can still investigate.
			warn "$scriptname: The $f does not seem to contain a valid DMARC report. Skipped and Removed. Content:\n";
			warn $filecontent."\n";
			return 2; #xml not ok (!1), delete file (2)
		}
	}

	if ($xml) {
		return 1;
	} else {
		warn "$scriptname: The $f does not seem to contain a valid DMARC report. Skipped.\n";
		return 0;
	}
}


################################################################################

# Walk through a mime message and return a reference to the XML data containing
# the fields of the first ZIPed XML file embedded into the message. The XML
# itself is not checked to be a valid DMARC report.
sub getXMLFromMessage {
	my ($message) = (@_);
	
	# fixup type in trustwave SEG mails
        $message =~ s/ContentType:/Content-Type:/;

	my $parser = new MIME::Parser;
	$parser->output_dir("/tmp");
	$parser->filer->ignore_filename(1);
	my $ent = $parser->parse_data($message);

	my $body = $ent->bodyhandle;
	my $mtype = $ent->mime_type;
	my $subj = decode_mimewords($ent->get('subject'));
	chomp($subj); # Subject always contains a \n.

	if ($debug) {
		print "Subject: $subj\n";
		print "MimeType: $mtype\n";
	}

	my $location;
	my $isgzip = 0;

	if(lc $mtype eq "application/zip") {
		if ($debug) {
			print "This is a ZIP file \n";
		}

		$location = $body->path;

	} elsif (lc $mtype eq "application/gzip" or lc $mtype eq "application/x-gzip") {
		if ($debug) {
			print "This is a GZIP file \n";
		}

		$location = $body->path;
		$isgzip = 1;

	} elsif (lc $mtype =~ "multipart/") {
		# At the moment, nease.net messages are multi-part, so we need
		# to breakdown the attachments and find the zip.
		if ($debug) {
			print "This is a multipart attachment \n";
		}
		#print Dumper($ent->parts);

		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
			my $part = $ent->parts($i);

			# Find a zip file to work on...
			if(lc $part->mime_type eq "application/gzip" or lc $part->mime_type eq "application/x-gzip") {
				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				$isgzip = 1;
				print "$location\n" if $debug;
				last; # of parts
			} elsif(lc $part->mime_type eq "application/x-zip-compressed"
				or $part->mime_type eq "application/zip") {

				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				print "$location\n" if $debug;
			} elsif(lc $part->mime_type eq "application/octet-stream") {
				$location = $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				$isgzip = 1 if $location =~ /\.gz$/;
				print "$location\n" if $debug;
			} else {
				# Skip the attachment otherwise.
				if ($debug) {
					print "Skipped an unknown attachment (".lc $part->mime_type.")\n";
				}
				next; # of parts
			}
		}
	} else {
		## Clean up dangling mime parts in /tmp of messages without ZIP.
		my $num_parts = $ent->parts;
		for (my $i=0; $i < $num_parts; $i++) {
			if ($debug) {
				if ($ent->parts($i)->{ME_Bodyhandle} && $ent->parts($i)->{ME_Bodyhandle}->{MB_Path}) {
					print $ent->parts($i)->{ME_Bodyhandle}->{MB_Path};
				} else {
					print "undef";
				}
				print "\n";
			}
			if($ent->parts($i)->{ME_Bodyhandle}) {$ent->parts($i)->{ME_Bodyhandle}->purge;}
		}
	}


	# If a ZIP has been found, extract XML and parse it.
	my $xml;
	if(defined($location)) {
		if ($debug) {
			print "body is in " . $location . "\n";
		}

		# Open the zip file and process the XML contained inside.
		my $unzip = "";
		if($isgzip) {
			open(XML, "<:gzip", $location)
			or $unzip = "ungzip";
		} else {
			open(XML, "-|", "unzip", "-p", $location)
			or $unzip = "unzip"; # Will never happen.

			# Sadly unzip -p never failes, but we can check if the
			# filehandle points to an empty file and pretend it did
			# not open/failed.
			if (eof XML) {
				$unzip = "unzip";
			}
		}

		# Read XML if possible (if open)
		if ($unzip eq "") {
			$xml = getXMLFromXMLString(join("", <XML>));
			if (!$xml) {
				warn "$scriptname: Subject: $subj\n:";
				warn "$scriptname: The XML found in ZIP file (temp. location: <$location>) does not seem to be valid XML! \n";
			}
			close XML;
		} else {
			warn "$scriptname: Subject: $subj\n:";
			warn "$scriptname: Failed to $unzip ZIP file (temp. location: <$location>)! \n";
			close XML;
		}
	} else {
		warn "$scriptname: Subject: $subj\n:";
		warn "$scriptname: Could not find an embedded ZIP! \n";
	}

	if($body) {$body->purge;}
	if($ent) {$ent->purge;}
	return $xml;
}

################################################################################

sub getXMLFromZip {
	my $filename = $_[0];
	my $mtype = mimetype($filename);

	if ($debug) {
		print "Filename: $filename, MimeType: $mtype\n";
	}

	my $isgzip = 0;

	if(lc $mtype eq "application/zip") {
		if ($debug) {
			print "This is a ZIP file \n";
		}
	} elsif (lc $mtype eq "application/gzip" or lc $mtype eq "application/x-gzip") {
		if ($debug) {
			print "This is a GZIP file \n";
		}

		$isgzip = 1;
	} else {
		if ($debug) {
			print "This is not an archive file \n";
		}
	}

	# If a ZIP has been found, extract XML and parse it.
	my $xml;
	if(defined($filename)) {
		# Open the zip file and process the XML contained inside.
		my $unzip = "";
		if($isgzip) {
			open(XML, "<:gzip", $filename)
			or $unzip = "ungzip";
		} else {
			open(XML, "-|", "unzip", "-p", $filename)
			or $unzip = "unzip"; # Will never happen.

			# Sadly unzip -p never failes, but we can check if the
			# filehandle points to an empty file and pretend it did
			# not open/failed.
			if (eof XML) {
				$unzip = "unzip";
			}
		}

		# Read XML if possible (if open)
		if ($unzip eq "") {
			$xml = getXMLFromXMLString(join("", <XML>));
			if (!$xml) {
				warn "$scriptname: The XML found in ZIP file (<$filename>) does not seem to be valid XML! \n";
			}
			close XML;
		} else {
			warn "$scriptname: Failed to $unzip ZIP file (<$filename>)! \n";
			close XML;
		}
	} else {
		warn "$scriptname: Could not find an <$filename>! \n";
	}

	return $xml;
}

################################################################################

sub getXMLFromXMLString {
	my $raw_xml = $_[0];

	eval {
		my $xs = XML::Simple->new();
		my $ref = $xs->XMLin($raw_xml, SuppressEmpty => '');
		$ref->{'raw_xml'} = $raw_xml;

		return $ref;
	} or do {
		return undef;
	}
}


################################################################################

# Extract fields from the XML report data hash and store them into the database.
# return 1 when ok, 0, for serious error and -1 for minor errors
sub storeXMLInDatabase {
	my $xml = $_[0]; # $xml is a reference to the xml data

	my $from = $xml->{'report_metadata'}->{'date_range'}->{'begin'};
	my $to = $xml->{'report_metadata'}->{'date_range'}->{'end'};
	my $org = $xml->{'report_metadata'}->{'org_name'};
	my $id = $xml->{'report_metadata'}->{'report_id'};
	my $email = $xml->{'report_metadata'}->{'email'};
	my $extra = $xml->{'report_metadata'}->{'extra_contact_info'};
        my $domain  = undef;
        my $policy_adkim = undef;
        my $policy_aspf = undef;
        my $policy_p = undef;
        my $policy_sp = undef;
        my $policy_pct = undef;
 
        if (ref $xml->{'policy_published'} eq "HASH") {
                $domain =  $xml->{'policy_published'}->{'domain'};
                $policy_adkim = $xml->{'policy_published'}->{'adkim'};
                $policy_aspf = $xml->{'policy_published'}->{'aspf'};
                $policy_p = $xml->{'policy_published'}->{'p'};
                $policy_sp = $xml->{'policy_published'}->{'sp'};
                $policy_pct = $xml->{'policy_published'}->{'pct'};
         } else {
                $domain =  $xml->{'policy_published'}[0]->{'domain'};
                $policy_adkim = $xml->{'policy_published'}[0]->{'adkim'};
                $policy_aspf = $xml->{'policy_published'}[0]->{'aspf'};
                $policy_p = $xml->{'policy_published'}[0]->{'p'};
                $policy_sp = $xml->{'policy_published'}[0]->{'sp'};
                $policy_pct = $xml->{'policy_published'}[0]->{'pct'};
        }

	my $record = $xml->{'record'};
	if ( ! defined($record) ) {
		warn "$scriptname: $org: $id: No records in report. Skipped.\n";
		return 0;
	}

	# begin transaction
	if ($db_tx_support) {
		$dbh->do(qq{START TRANSACTION});
		if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot start transaction. Continuing without transaction support.\n";
				$db_tx_support = 0;
		}
	}
	# see if already stored
	my $sth = $dbh->prepare(qq{SELECT org, serial FROM report WHERE reportid=?});
	$sth->execute($id);
	while ( my ($xorg,$sid) = $sth->fetchrow_array() )
	{
		if ($reports_replace) {
			# $sid is the serial of a report with reportid=$id
			# Remove this $sid from rptrecord and report table, but
			# try to continue on failure rather than skipping.
			print "$scriptname: $org: $id: Replacing data.\n";
			$dbh->do(qq{DELETE from rptrecord WHERE serial=?}, undef, $sid);
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot remove report data from database. Try to continue.\n";
			}
			$dbh->do(qq{DELETE from report WHERE serial=?}, undef, $sid);
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot remove report from database. Try to continue.\n";
			}
		} else {
			print "$scriptname: $org: $id: Already have report, skipped\n";
			# Do not store in DB, but return true, so the message can
			# be moved out of the way, if configured to do so.
			return 1;
		}
	}

	my $sql = qq{INSERT INTO report(serial,mindate,maxdate,domain,org,reportid,email,extra_contact_info,policy_adkim, policy_aspf, policy_p, policy_sp, policy_pct, raw_xml)
			VALUES(NULL,FROM_UNIXTIME(?),FROM_UNIXTIME(?),?,?,?,?,?,?,?,?,?,?,?)};
	my $storexml = $xml->{'raw_xml'};
	if ($compress_xml) {
		my $gzipdata;
		if(!gzip(\$storexml => \$gzipdata)) {
			warn "$scriptname: $org: $id: Cannot add gzip XML to database ($GzipError). Skipped.\n";
			return 0;
			$storexml = "";
		} else {
			$storexml = encode_base64($gzipdata, "");
		}
	}
	if (length($storexml) > $maxsize_xml) {
		warn "$scriptname: $org: $id: Skipping storage of large XML (".length($storexml)." bytes) as defined in config file.\n";
		$storexml = "";
	}
	$dbh->do($sql, undef, $from, $to, $domain, $org, $id, $email, $extra, $policy_adkim, $policy_aspf, $policy_p, $policy_sp, $policy_pct, $storexml);
	if ($dbh->errstr) {
		warn "$scriptname: $org: $id: Cannot add report to database. Skipped.\n";
		return 0;
	}

	my $serial = $dbh->{'mysql_insertid'} ||  $dbh->{'insertid'};
	if ($debug){
		print " serial $serial \n";
	}
	sub dorow($$$$) {
		my ($serial,$recp,$org,$id) = @_;
		my %r = %$recp;

		my $ip = $r{'row'}->{'source_ip'};
		if ( $ip eq '' ) {
			warn "$scriptname: $org: $id: source_ip is empty. Skipped.\n";
			return 0;
		}
		my $count = $r{'row'}->{'count'};
		my $disp = $r{'row'}->{'policy_evaluated'}->{'disposition'};
		if ( ! grep { $_ eq $disp } ALLOWED_DISPOSITION ) {
			$disp = 'unknown';
		};
		 # some reports don't have dkim/spf, "unknown" is default for these
		my $dkim_align = $r{'row'}->{'policy_evaluated'}->{'dkim'};
		if ( ! grep { $_ eq $dkim_align } ALLOWED_DKIM_ALIGN ) {
			$dkim_align = 'unknown';
		};
		my $spf_align = $r{'row'}->{'policy_evaluated'}->{'spf'};
		if ( ! grep { $_ eq $spf_align } ALLOWED_SPF_ALIGN ) {
			$spf_align = 'unknown';
		};

		my $identifier_hfrom = $r{'identifiers'}->{'header_from'};

		my ($dkim, $dkimresult, $spf, $spfresult, $reason);
		if(ref $r{'auth_results'} ne "HASH"){
			warn "$scriptname: $org: $id: Report has no auth_results data. Skipped.\n";
			return 0;
		}
		my $rp = $r{'auth_results'}->{'dkim'};
		if(ref $rp eq "HASH") {
			$dkim = $rp->{'domain'};
			$dkim = undef if ref $dkim eq "HASH";
			$dkimresult = $rp->{'result'};
		} else { # array, i.e. multiple dkim results (usually from multiple domains)
			# glom sigs together
			$dkim = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"?"": $d } @$rp;
			# report results
			my $rp_len = scalar(@$rp);
			for ( my $i=0; $i < $rp_len; $i++ ) {
				if ( $rp->[$i]->{'result'} eq "pass" ) {
					# If any one dkim result is a "pass", this should yield an overall "pass" and immediately exit the for loop, ignoring any remaing results
					# See
					# RFC 6376, DomainKeys Identified Mail (DKIM) Signatures
					# 	Section 4.2: https://tools.ietf.org/html/rfc6376#section-4.2 and
					# 	Section 6.1: https://tools.ietf.org/html/rfc6376#section-6.1
					# And the GitHub issues at
					#	https://github.com/techsneeze/dmarcts-report-viewer/issues/47
					#	https://github.com/techsneeze/dmarcts-report-parser/pull/78
					$dkimresult = "pass";
					last;
				} else {
					for ( my $j=$i+1; $j < $rp_len; $j++ ) {
						if ( $rp->[$i]->{'result'} eq $rp->[$j]->{'result'} ) {
						# Compare each dkim result to the next one to see if all of the dkim results are the same.
						# If all of the dkim results are the same, that will be the overall result.
						# If any of them are different, and don't contain a "pass" result, then $dkimresult will be empty
							$dkimresult = $rp->[0]->{'result'};
						} else {
							$dkimresult = 'unknown';
						}
					}
				}
			}
		}
		if ( ! defined($dkimresult) || ! grep { $_ eq $dkimresult } ALLOWED_DKIMRESULT ) {
			$dkimresult = 'unknown';
		};

		$rp = $r{'auth_results'}->{'spf'};
		if(ref $rp eq "HASH") {
			$spf = $rp->{'domain'};
			$spf = undef if ref $spf eq "HASH";
			$spfresult = $rp->{'result'};
		} else { # array, i.e. multiple dkim results (usually from multiple domains)
			# glom sigs together
			$spf = join '/',map { my $d = $_->{'domain'}; ref $d eq "HASH"?"": $d } @$rp;
			# report results
			my $rp_len = scalar(@$rp);
			for ( my $i=0; $i < $rp_len; $i++ ) {
				if ( $rp->[$i]->{'result'} eq "pass" ) {
					# If any one spf result is a "pass", this should yield an overall "pass" and immediately exit the for loop, ignoring any remaing results
					$spfresult = "pass";
					last;
				} else {
					for ( my $j=$i+1; $j < $rp_len; $j++ ) {
						if ( $rp->[$i]->{'result'} eq $rp->[$j]->{'result'} ) {
						# Compare each spf result to the next one to see if all of the spf results are the same.
						# If all of the spf results are the same, that will be the overall result.
						# If any of them are different, and don't contain a "pass" result, then $spfresult will be empty
							$spfresult = $rp->[0]->{'result'};
						} else {
							$spfresult = 'unknown';
						}
					}
				}
			}
		}
		if ( ! defined($spfresult) || ! grep { $_ eq $spfresult } ALLOWED_SPFRESULT ) {
			$spfresult = 'unknown';
		};

		$rp = $r{'row'}->{'policy_evaluated'}->{'reason'};
		if(ref $rp eq "HASH") {
			$reason = $rp->{'type'};
		} else {
			$reason = join '/',map { $_->{'type'} } @$rp;
		}
		#print "ip=$ip, count=$count, disp=$disp, r=$reason,";
		#print "dkim=$dkim/$dkimresult, spf=$spf/$spfresult\n";

		# What type of IP address?
		my ($nip, $iptype, $ipval);
		if ($debug) {
			print "ip=$ip\n";
		}
		if($nip = inet_pton(AF_INET, $ip)) {
			$ipval = unpack "N", $nip;
			$iptype = "ip";
		} elsif($nip = inet_pton(AF_INET6, $ip)) {
			$ipval = "X'" . unpack("H*",$nip) . "'";
			$iptype = "ip6";
		} else {
			warn "$scriptname: $org: $id: ??? mystery ip $ip\n";
			return 0;
		}

		$dbh->do(qq{INSERT INTO rptrecord(serial,$iptype,rcount,disposition,spf_align,dkim_align,reason,dkimdomain,dkimresult,spfdomain,spfresult,identifier_hfrom)
			VALUES(?,$ipval,?,?,?,?,?,?,?,?,?,?)},undef,$serial,$count,$disp,$spf_align,$dkim_align,$reason,$dkim,$dkimresult,$spf,$spfresult,$identifier_hfrom);
		if ($dbh->errstr) {
			warn "$scriptname: $org: $id: Cannot add report data to database. Skipped.\n";
			return 0;
		}
		return 1;
	}

	my $res = 1;
	if(ref $record eq "HASH") {
		if ($debug){
			print "single record\n";
		}
		$res = -1 if !dorow($serial,$record,$org,$id);
	} elsif(ref $record eq "ARRAY") {
		if ($debug){
			print "multi record\n";
		}
		foreach my $row (@$record) {
			$res = -1 if !dorow($serial,$row,$org,$id);
		}
	} else {
		warn "$scriptname: $org: $id: mystery type " . ref($record) . "\n";
	}

	if ($debug && $res <= 0) {
		print "Result $res XML: $xml->{raw_xml}\n";
	}

	if ($res <= 0) {
		if ($db_tx_support) {
			warn "$scriptname: $org: $id: Cannot add records to rptrecord. Rolling back DB transaction.\n";
			$dbh->do(qq{ROLLBACK});
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot rollback transaction.\n";
			}
		} else {
			warn "$scriptname: $org: $id: errors while adding to rptrecord, serial $serial records likely obsolete.\n";
		}
	} else {
		if ($db_tx_support) {
			$dbh->do(qq{COMMIT});
			if ($dbh->errstr) {
				warn "$scriptname: $org: $id: Cannot commit transaction.\n";
			}
		}
	}
	return $res;
}


################################################################################

# Check, if the database contains needed tables and columns. The idea is, that
# the user only has to create the database/database_user. All needed tables and
# columns are created automatically. Furthermore, if new columns are introduced,
# the user does not need to make any changes to the database himself.
sub checkDatabase {
	my $dbh = $_[0];

	my %tables = (
		"report" => {
			column_definitions 		=> [
				"serial"		, "int(10) unsigned NOT NULL AUTO_INCREMENT",
				"mindate"		, "timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP",
				"maxdate"		, "timestamp NULL",
				"domain"		, "varchar(255) NOT NULL",
				"org"			, "varchar(255) NOT NULL",
				"reportid"		, "varchar(255) NOT NULL",
				"email"			, "varchar(255) NULL",
				"extra_contact_info"	, "varchar(255) NULL",
				"policy_adkim"		, "varchar(20) NULL",
				"policy_aspf"		, "varchar(20) NULL",
				"policy_p"		, "varchar(20) NULL",
				"policy_sp"		, "varchar(20) NULL",
				"policy_pct"		, "tinyint unsigned",
				"raw_xml"		, "mediumtext",
				],
			additional_definitions 		=> "PRIMARY KEY (serial), UNIQUE KEY domain (domain,reportid)",
			table_options			=> "ROW_FORMAT=COMPRESSED",
			},
		"rptrecord" =>{
			column_definitions 		=> [
				"id"			, "int(10) unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY",
				"serial"		, "int(10) unsigned NOT NULL",
				"ip"			, "int(10) unsigned",
				"ip6"			, "binary(16)",
				"rcount"		, "int(10) unsigned NOT NULL",
				"disposition"		, "enum('" . join("','", ALLOWED_DISPOSITION) . "')",
				"reason"		, "varchar(255)",
				"dkimdomain"		, "varchar(255)",
				"dkimresult"		, "enum('" . join("','", ALLOWED_DKIMRESULT) . "')",
				"spfdomain"		, "varchar(255)",
				"spfresult"		, "enum('" . join("','", ALLOWED_SPFRESULT) . "')",
				"spf_align"		, "enum('" . join("','", ALLOWED_SPF_ALIGN) . "') NOT NULL",
				"dkim_align"		, "enum('" . join("','", ALLOWED_DKIM_ALIGN) . "') NOT NULL",
				"identifier_hfrom"	, "varchar(255)",
				],
			additional_definitions 		=> "KEY serial (serial,ip), KEY serial6 (serial,ip6)",
			table_options			=> "",
			},
	);

	# Get current tables in this DB.
	my %db_tbl_exists = ();
	for ( @{ $dbh->selectall_arrayref( "SHOW TABLES;") } ) {
		$db_tbl_exists{$_->[0]} = 1;
	}

	# Create missing tables and missing columns.
	for my $table ( keys %tables ) {

		if (!$db_tbl_exists{$table}) {

			# Table does not exist, build CREATE TABLE cmd from tables hash.
			print "$scriptname: Adding missing table <" . $table . "> to the database.\n";
			my $sql_create_table = "CREATE TABLE " . $table . " (\n";
			for (my $i=0; $i <= $#{$tables{$table}{"column_definitions"}}; $i+=2) {
				my $col_name = $tables{$table}{"column_definitions"}[$i];
				my $col_def = $tables{$table}{"column_definitions"}[$i+1];
				# add comma if second or later entry
				if ($i != 0) {
					$sql_create_table .= ",\n";
				}
				$sql_create_table .= $col_name . " " .$col_def;
			}
			# Add additional_definitions, if defined.
			if ($tables{$table}{"additional_definitions"} ne "") {
				$sql_create_table .= ",\n" . $tables{$table}{"additional_definitions"};
			}
			# Add options.
			$sql_create_table .= ") " . $tables{$table}{"table_options"} . ";";
			# Create table.
			print "$sql_create_table\n" if $debug;
			$dbh->do($sql_create_table);
		} else {

			#Table exists, get  current columns in this table from DB.
			my %db_col_exists = ();
			for ( @{ $dbh->selectall_arrayref( "SHOW COLUMNS FROM $table;") } ) {
				$db_col_exists{$_->[0]} = $_->[1];
			};

			# Check if all needed columns are present, if not add them at the desired position.
			my $insert_pos = "FIRST";
			for (my $i=0; $i <= $#{$tables{$table}{"column_definitions"}}; $i+=2) {
				my $col_name = $tables{$table}{"column_definitions"}[$i];
				my $col_def = $tables{$table}{"column_definitions"}[$i+1];
				my $short_def = $col_def;
				$short_def =~ s/ +.*$//;
				if (!$db_col_exists{$col_name}) {
					# add column
					my $sql_add_column = "ALTER TABLE $table ADD $col_name $col_def $insert_pos;";
					print "$sql_add_column\n" if $debug;
					$dbh->do($sql_add_column);
				} elsif ($db_col_exists{$col_name} !~ /^\Q$short_def\E/) {
					# modify column
					my $sql_modify_column = "ALTER TABLE $table MODIFY COLUMN $col_name $col_def;";
					print "$sql_modify_column\n" if $debug;
					$dbh->do($sql_modify_column);
				}
				$insert_pos = "AFTER $col_name";
			}
		}
	}
}
