# dmarcts-report-parser
A Perl based tool to parse DMARC reports, based on John Levine's [rddmarc](http://www.taugh.com/rddmarc/), but extended by the following features:
* Allow to read messages from an IMAP server and not only from the local filesystem.
* Store much more XML values into the database (for example the missing SPF and DKIM results from the policy_evaluated section) and also the entire XML for later reference.
* Needed database tables and columns are created automatically, user only needs to provide a database. The database schema is compatible to the one used by rddmarc, but extends it by additional fields. Users can switch from rddmarc to dmarcts-report-parser without having to do any changes to the database by themselves.
* Due to limitations in stock configurations of MySQL/MariaSQL on some distros, it may be necessary
to add the following to your configuration (i.e. in /etc/mysql/mariadb.conf.d/50-server.cnf):

```
innodb_large_prefix	= on
innodb_file_format	= barracuda
innodb_file_per_table	= true
```

## Installation and Configuration

To install dependencies...

### on Debian:
```
apt-get install libfile-mimeinfo-perl libmail-imapclient-perl libmime-tools-perl libxml-simple-perl \
libclass-dbi-mysql-perl libio-socket-inet6-perl libio-socket-ip-perl libperlio-gzip-perl \
libmail-mbox-messageparser-perl unzip
```
### on Fedora (Fedora 23):
```
sudo dnf install perl-File-MimeInfo perl-Mail-IMAPClient perl-MIME-tools perl-XML-Simple perl-DBI \
 perl-Socket6 perl-PerlIO-gzip perl-DBD-MySQL unzip
```
### on CentOS (CentOS 7):
```
yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum install perl-File-MimeInfo perl-Mail-IMAPClient perl-MIME-tools perl-XML-Simple perl-DBI \
 perl-Socket6 perl-PerlIO-gzip perl-DBD-MySQL unzip perl-Mail-Mbox-MessageParser
 ```
### on FreeBSD (FreeBSD 11.4):
```
sudo pkg install p5-File-MimeInfo p5-Mail-IMAPClient p5-MIME-tools p5-XML-Simple p5-DBI p5-Socket6 p5-PerlIO-gzip p5-DBD-MySQL p5-Mail-Mbox-MessageParser unzip
```

 ### on macOS (macOS 10.13):
```
brew install mysql shared-mime-info
update-mime-database /usr/local/share/mime
perl -MCPAN -e 'install Mail::IMAPClient'
perl -MCPAN -e 'install Mail::Mbox::MessageParser'
perl -MCPAN -e 'install File::MimeInfo'
perl -MCPAN -e 'install DBD::mysql'
```

To get your copy of the dmarcts-report-parser, you can either clone the repository:
```
git clone https://github.com/techsneeze/dmarcts-report-parser.git
```
or download a zip file containg all files from [here](https://github.com/techsneeze/dmarcts-report-parser/archive/master.zip). Once the files have been downloaded, you will need to copy/rename `dmarcts-report-parser.conf.sample` to `dmarcts-report-parser.conf`. Next, edit the configuration options:

```
################################################################################
### configuration ##############################################################
################################################################################

# If IMAP access is not used, config options starting with $imap do not need to
# be set and are ignored.

$debug = 0;
$delete_reports = 0;

$dbname = 'dmarc';
$dbuser = 'dmarc';
$dbpass = 'password';
$dbhost = 'dbhost'; # Set the hostname if we can't connect to the local socket.
$dbport = '3306';

$imapserver       = 'imap.server';
$imapuser         = 'username';
$imappass         = 'password';
$imapport         = '143';
$imapssl          = '0';        # If set to 1, remember to change server port to 993 and disable imaptls.
$imaptls          = '0';        # Enabled as the default and best-practice.
$tlsverify        = '0';        # Enable verify server cert as the default and best-practice.
$imapignoreerror  = '0';          # set it to 1 if you see an "ERROR: message_string() 
                                # expected 119613 bytes but received 81873 you may 
                                # need the IgnoreSizeErrors option" because of malfunction
                                # imap server as MS Exchange 2007, ...
$imapreadfolder   = 'dmarc';

# If $imapmovefolder is set, processed IMAP messages will be moved (overruled by
# the --delete option!)
$imapmovefolder = 'dmarc/processed';

# maximum size of XML files to store in database, long files can cause transaction aborts
$maxsize_xml = 50000;
# store XML as base64 encopded gzip in database (save space, harder usable)
$compress_xml = 0;

# if there was an error during file processing (message does not contain XML or ZIP parts, 
# or a database error) the parser reports an error and does not delete the file, even if 
# delete_reports is set (or --delete is given). Deletion can be enforced by delete_failed, 
# however not for database errors.
$delete_failed = 0;
```
The script is looking for `dmarcts-report-parser.conf` in the current working directory. If not found it will look by the calling path. If neither is found than it will abort.

Note: Be sure to use the proper hierarchy separator for your server in all folder specs, and
if your IMAP server flattens the hierarchy (i.e. Cyrus IMAP with "altnamespace: yes") then
leave "Inbox" off of the beginning of such specs.

## Usage

```
./dmarcts-report-parser.pl [OPTIONS] [PATH]
```
PATH can be the filename of a single file or a list of files - wildcard expression are allowed.

**Remember**: This script needs a configurations file called <dmarcts-report-parser.conf> in the current working directory, which defines a database server with credentials and (if used) an IMAP server with credentials.

One of the following source options must be provided:
```
#        -i : Read reports from messages on IMAP server as defined in the config file.
#        -m : Read reports from mbox file(s) provided in PATH.
#        -e : Read reports from MIME email file(s) provided in PATH.
#        -x : Read reports from xml file(s) provided in PATH.
#        -z : Read reports from zip file(s) provided in PATH.
```

The following options are always allowed:
```
#        -d : Print debug info.
#        -r : Replace existing reports rather than failing.
#  --delete : Delete processed message files (the XML is stored in the
#             database for later reference).
```

More info can currently be found at : [TechSneeze.com](http://www.techsneeze.com/how-parse-dmarc-reports-imap/)
