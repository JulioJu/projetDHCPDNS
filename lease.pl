#!/usr/bin/env perl

#=============================================================================== {{{1
#
#              FILE: lease.pl
#
#             USAGE: export DHCP_OMAPI_DEBUG=1 && ./lease.pl
#       DESCRIPTION:
# Before execute this script, to have debug mode you shall type :
# export DHCP_OMAPI_DEBUG=1;
#           OPTIONS: ---
#      REQUIREMENTS:
# ssh server shall listen on port 22, and security exeption must be already added at the first connection (before script execution).
# DHCP server shall be active and properly set up with OMAPI.
# DHCP requierement (see dhcpd.lease manpage) : « dhcpd requires that a lease database be present before it will start. ».
# For this programm, it should be on /var/lib/dhcp/dhcpd.leases.
# Mysql must be already created with
# CREATE TABLE `$MYSQL_DATABASE`.`$MYSQL_TABLE` ( `mac` VARCHAR(17) NOT NULL , `ip` VARCHAR(3) NOT NULL , `hostname` VARCHAR(40) NOT NULL , PRIMARY KEY (`mac`(17)), UNIQUE (`ip`(3)), UNIQUE (`hostname`(20))) ENGINE = InnoDB;
# for example
# CREATE TABLE `tpreseau2`.`network` ( `mac` VARCHAR(17) NOT NULL , `ip` VARCHAR(3) NOT NULL , `hostname` VARCHAR(40) NOT NULL , PRIMARY KEY (`mac`(17)), UNIQUE (`ip`(3)), UNIQUE (`hostname`(20))) ENGINE = InnoDB;
# WARNING, PAY ATTENTION
# FROM NSUPDATE MANUAL PAGE
# « Zones that are under dynamic control via nsupdate or a DHCP server should not be edited by hand. Manual edits could conflict with dynamic updates and cause data to be lost »
# This script is very verbose.
# This script should not be readable and writable by other than owner, as all dhcp and bind files.
# bind-utils should be installed on computer where this script is executed.
# You must allow remote dhcp user restart DHCP (with ArchLinux %named ns1= NOPASSWD: /usr/sbin/systemctl restart dhcpd4.service)
# Sometimes rndc databases aren't imnediatly synchronized, f there is a probem, synchronise with command rndc (see subroutine rndc).
# If something goes bad, think see bind9 and DHCPD log.
# This code is very comment in « say » functions. To know it, you must see also omshell, nsupdate, rndc and dhcpd.leases manpage.
# For Marionnet, before start, configure ip DHCP and DNS IP. To know it, use « ip route » in host. In DNS server, configure /etc/bind/named.conf.options, bloc control. You must update inet ip, (see echo $DISPLAY in guest).
# In command-line, if you choose « changeIP », and you have « --hostname », « --hostname » will be not used in first main loop.
# @TODO Add scripted mode, do not ask confirmation and terminate script at the end of action executed.
# nsupdate doesn't work with Marionnet
#              BUGS: ---
#             NOTES: ---
#            AUTHOR: Julio, juanes 0890 A\\t g\\\ mail
#      ORGANIZATION: Université Grenoble 2
#           VERSION: 1.0
#           CREATED: 08/06/16 17:15:00
#          REVISION: 23/07/16 
#===============================================================================

use feature qw(say switch evalbytes);
use strict;
use Net::ISC::DHCPd::Leases;
use Net::OpenSSH;

# use Net::ISC::DHCPd::OMAPI; Tested very bad. Errors in documentation, and maybe not functionnal for make changes.

use Getopt::Long qw(:config no_ignore_case bundling auto_abbrev);
use DBI;

use Net::Ping; # Not used (commented) if there is _ deny unknown-clients » in dhcpd.conf
# use File::Tee qw(tee); # Doesn't work as I would like (for OMSHELL). And I don't see how close it.

use List::MoreUtils qw(first_index);    # For array index of one element

use sigtrap qw(handler my_handler normal-signals stack-trace error-signals);
#-------------------------------------------------------------------------------
#  Define constants {{{1
#-------------------------------------------------------------------------------

my $ACTION                  = ""; # Could be redefined if there is an error or if if we restart programm
my $ACTIONNUM               = ""; # Could be redefined if there is an error or if if we restart programm
my $MAC                     = ""; # Could be redefined if there is an error or if if we restart programm
my $IPNEW                   = ""; # Could be redefined if there is an error or if if we restart programm
my $HOSTNAMENEW             = ""; # Could be redefined if there is an error or if if we restart programm
my $DHCP_SERVER             = "172.23.0.3";
my $DHCP_USER               = "root";
my $DHCP_PASSWORD           = "root"; # TODO change authentification method
my $DHCP_COMMAND_RESTART    = "sudo service isc-dhcp-server restart"; # For debian Wheezy
# my $DHCP_COMMAND_RESTART  = "sudo systemctl restart dhcpd4.service"; # For ArchLinux, add %named ns1= NOPASSWD: /usr/sbin/systemctl restart dhcpd4.service
my $OMAPI_PORT              = "7911";
my $OMAPI_KEY               = "key omapi_key KSOfRy8uFiSAAcm3lsn+lQ=="; # TODO use rndc.key
my $DNS_SERVER_PRIMARY      = "172.23.0.4";
my $DNS_USER                = "root";
my $DNS_PASSWORD            = "root";
my $DNS_ZONE                = "imss.org.";
my $DNS_REVERSE_ZONE        = "1.168.192.in-addr.arpa.";
my $MYSQL_SERVER            = "127.0.0.1";
my $MYSQL_USER              = "root";
my $MYSQL_PASSWORD          = "";                               # Not parameter
my $MYSQL_DATABASE          = "tpreseau2";
my $MYSQL_TABLE             = "network";
my $NETWORK                 = "192.168.1.";
my $NETWORK_PARAMETER       = "network";
my $NETWORK_FIRST_IP        = 5;
my $NETWORK_LAST_IP         = 200;

#-------------------------------------------------------------------------------
#  Command line options {{{1
#-------------------------------------------------------------------------------

GetOptions(
    "action=s"     => \$ACTION,
    "actionnum=i"  => \$ACTIONNUM,
    "mac=s"        => \$MAC,
    "ipnew=i"      => \$IPNEW,
    "hostname=s"   => \$HOSTNAMENEW,
) or die("Error in command line\n\n");

#-------------------------------------------------------------------------------
#  Subroutines for choose action or/and validate action {{{1
#-------------------------------------------------------------------------------


sub isGoodParametersActions {
    if ( $ACTION ne "" and $ACTIONNUM ne "" ) {
        warn "You can't have « --actionNum » and « --action » in a same command-line. Fatal error, script aborted";
        exit 3;
    }
}

sub printWelcomToProgramm {
    say "\n\n——————— Programm $0 for manage hosts in DHCP and DNS servers ——————————";
    if ( $ACTION eq "" ) {
        say "Tips and tricks :
            You can also execute this script with options :
                * for create a new host : ./$0 --action=create --mac=new_mac_adress --ipnew=ip_v4_address --hostname=name_of_host
                * for change an ip host : ./$0 --action=changeip --mac=mac_adress_host_already_saved --ipnew=ip_v4_address
                * for change a hostname : ./$0 --action=changehostname --mac=mac_adress_host_already_saved --ipnew=ip_v4_address
                * for add new actives leases (if dhcpd.conf have « allow unknown-clients ») : ./$0 --action=addfromdhcpdleasesfile (note tested).
                Note : For --action=changeip, --hostname is not relevant and for --action=changehostname --ipnew is not relevant so not used
        ";
    }
}

# All passed by value
sub isValidAction {
    # Command line analyisis and transform it into number
    SWITCH: {
        if ( $ACTION eq ""               ) {$ACTIONNUM = 0; last SWITCH; }
        if ( $ACTION eq "create"         ) {$ACTIONNUM = 1; last SWITCH; }
        if ( $ACTION eq "remove"         ) {$ACTIONNUM = 2; last SWITCH; }
        if ( $ACTION eq "changeip"       ) {$ACTIONNUM = 3; last SWITCH; }
        if ( $ACTION eq "changehostname" ) {$ACTIONNUM = 4; last SWITCH; }
        if ( $ACTION eq "addfromdhcpdleasesfile") {$ACTIONNUM = 5; last SWITCH; }
        say STDERR "« $ACTION » is not a valid action (create, remove, changeip, changeHostname or addfromdhcpdleasesfiles).";
    }
}

# All passed by references
sub isValidActionnum {
    my ($actionNum) = @_;
    if ( $$actionNum !~ /^[1-5a]$/ ) {
        if ( $$actionNum != 0 ) {
            say STDERR "« $$actionNum » is not a valid action.";
        }
        return 0;
    }
    return 1;
}

# All passed by references
sub chooseActionNum {
    my ($actionNum) = @_;
    while ( ! isValidActionnum($actionNum) ) {
        say "Please choose an action number
        [1] Create an new host
        [2] Remove an existing host
        [3] Change ip of an existing host
        [4] Change hostname of an existing host
        [5] Parse dhcpd leases file for add active leases (dhcpd.conf should haven't « deny/ignore unknown-clients »)
        [a] Do nothing, exit programm";
        chomp ($$actionNum = <STDIN>);
    }
}

#-------------------------------------------------------------------------------
#  Subroutines for action « create » ipChange and hostnameChange. For define good constants macNew (if mandatory), ipNew (if mandatory) and hostName (if mandatory)  {{{1
#-------------------------------------------------------------------------------

# All passed by value
sub isMac {
    my ($macvar) = @_;
    return 0 if ( $macvar eq "" );
    if ( $macvar !~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ ) {
        say STDERR "« $macvar » parameter is not a valid mac address.";
        return 0;
    }
    return 1;
}

# All passed by value
sub isIpNewValidIp {
    my ($ipvar) = @_;
    return 0 if ( $ipvar eq "" );
    if ( $ipvar !~ /^[0-9]{1,3}$/
        or ( $ipvar <= $NETWORK_FIRST_IP or $ipvar >= $NETWORK_LAST_IP )
        )
    {
        say STDERR "The ip « $ipvar » can't be used, because it's not a number or out of range $NETWORK_FIRST_IP-$NETWORK_LAST_IP.";
        return 0;
    }
    return 1;
}

# All passed by value
sub isHostname {
    my ($hostnamevar) = @_;
    return 0 if ( $hostnamevar eq "" );
    if ( $hostnamevar !~ /^[a-zA-Z0-9]{2,40}$/) {
        say STDERR "The ip « $hostnamevar » can't be used because it's not an alphanumeric name, or it has less than 2 or more than 40 letters.";
        return 0;
    }
    return 1;
}

# All passed by value, expect $constant.
sub defineConstanteUsable {
    my ($arrayUsed, $constant, $function, $name) = @_;
    my $present = first_index { $_ eq $$constant } @$arrayUsed;
    while ( ! evalbytes($function) or ( $present ne -1 )) {
        if ( $present ne -1 ) {
            say STDERR "$name « $$constant » can't be used, because it's already used.";
        }
        say "\n$name already used:";
        say join "\n    ", "    @$arrayUsed";
        say "Empty list" if ( $#$arrayUsed lt 0);
        say "End of list.";
        say "Type an new $name not already used, or « a » to abort programm.";
        chomp ($$constant=<STDIN>);
        $present = first_index { $_ eq $$constant } @$arrayUsed;
        if ( $$constant eq "a" ) {
            warn "Script aborted by user";
            exit 0;
        }
    }
}

#-------------------------------------------------------------------------------
#  Subroutines for define an existing macKey {{{1
#-------------------------------------------------------------------------------

# All passed by value, expect $macKey.
sub defineMacKey {
    my ($macKey, $macUsed, $ipUsed, $hostnameUsed) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;
    my $index = first_index { $_ eq "$$macKey" } @macUsed;
    if ($index eq -1) {
        say "$$macKey is not present in Mysql database. Please chose another.";
        my $choose = -1;
        while ($choose lt 0 or $choose gt $#macUsed) {
            say "Host already difined:";
            foreach $index (0 .. $#macUsed) {
                say "   [$index] mac: $macUsed[$index], ip: $ipUsed[$index], hostname: $hostnameUsed[$index]";
            }
            say "Choose host number";
            chomp ($choose = <STDIN>);
        }
        $$macKey = $macUsed[$choose];
    }

}

#-------------------------------------------------------------------------------
#  Subroutines OMSHELL, rndc, nsupdate, mysql {{{1
#-------------------------------------------------------------------------------

# All passed by value
sub openOMSHELL {
    say "* DHCP Lease database updating with omshell…";

    # http://stevesprogramming.blogspot.fr/2010/10/perl-writing-stderr-to-variable.html
    my $stdoutAndStderr = "/tmp/omshellStdoutAndStderr.tmp";
    unlink $stdoutAndStderr;
    say "STDOUT and STDERR redirect into $stdoutAndStderr…";
    open (OLDOUT, ">&", \*STDOUT) || die "Can't dup stdout";
    open (OLDERR, ">&", \*STDERR) || die "Can't dup stderr";
    close STDOUT;
    close STDERR;
    open (STDOUT, ">>", $stdoutAndStderr) || die "Can't remap STDOUT";
    open (STDERR, ">>", $stdoutAndStderr) || die "Can't remap STDERR";

    my ( $mac ) = @_;
    my $name = $mac;
    $name =~ s/://g;
    open( OMSHELL, "|omshell" ) || die("Unable to open omshell\n");
    print OMSHELL "server $DHCP_SERVER\n";
    print OMSHELL "port $OMAPI_PORT\n";
    print OMSHELL "$OMAPI_KEY\n";
    print OMSHELL "connect\n";
    print OMSHELL "new host\n";
    print OMSHELL "set name = \"$name\"\n";
}

# All passed by value
sub closeOMSHELL {
    my ($actionNum) = $_;
    my $stdoutAndStderr = "/tmp/omshellStdoutAndStderr.tmp";
    close STDOUT;
    close STDERR;
    open (STDOUT, ">&", \*OLDOUT) || warn "Can't repoint STDOUT";
    open (STDERR, ">&", \*OLDERR) || warn "Can't repoint STDERR";
    close OLDOUT;
    close OLDERR;
    say "End STDOUT and STDERR redirection.";
    close(OMSHELL) || die "Unable to close omshell.\n";
    say "Success.";
    if ( $? gt 0 ) {
        warn "`omshell' closed with error $?.\nScript aborted. See $stdoutAndStderr.";
        exit 10;
    }

    open (IN, $stdoutAndStderr) || warn "Cannot open file ".$stdoutAndStderr." for read";
    my @lines=<IN>;
    close IN;

    say "\n* Print $stdoutAndStderr into standard output.";
    foreach my $line (@lines) {
        print $line;
    }

    say "\n* Looking for errors into $stdoutAndStderr";
    # my $parseOmshellOutput manually integred from dhcp-4.3.4/dhcptl/omshell.c. Maybe some all bad output aren't here.
    my $parseOmshellOutput = '
        $line =~ /unknown service name:/
        or $line =~ /unknown token:/
        or $line =~ /no memory to store server name/
        or $line =~ /no memory for key name/
        or $line =~ /an object is already open/
        or $line =~ /not connected/
        or $line =~ /can\'t create object/
        or $line =~ /not open/
        or $line =~ /invalid value/
        or $line =~ /no open object/
        or $line =~ /you must make a new object first/
        or $line =~ /you haven\'t opened an object yet/
        or $line =~ /can\'t update object:/
        or $line =~ /no object/
        or $line =~ /can\'t destroy object:/
        or $line =~ /can\'t refresh object:/
        or $line =~ /dhcpctl_connect:/
        or $line =~ /Cannot create authenticator:/
        or $line =~ /dhcpctl_connect:/
        or $line =~ /can\'t open object: already exists/
        ';
    if ( $actionNum != 1 ) {
        my $parseOmshellOutput = $parseOmshellOutput . '
        or $line =~ /can\'t open object/
        or $line =~ /can\'t destroy object:/
        ';
    }
    my $i = 0;
    foreach my $line (@lines) {
        if ( evalbytes($parseOmshellOutput) ) {
            warn "Error with omshell. See in file $stdoutAndStderr at line $i message : \n $line" ;
            exit 4;
        }
        $i = $i+1;
    }
    say "Omshell action seems performed successfully.";

    unlink $stdoutAndStderr;
}

# All passed by value
sub createHostInDHCPDLeases {
    my ( $mac, $ip, $hostname, $actionNum ) = @_;
    $ip = "$NETWORK$ip";
    openOMSHELL($mac, $actionNum);
    print OMSHELL "set hardware-address = $mac\n";
    print OMSHELL "set hardware-type = 1\n";
    print OMSHELL "set ip-address = $ip\n";
    print OMSHELL "set statements = \"ddns-hostname = \\\"$hostname\\\"; ddns-domainname = \\\"$DNS_ZONE\\\";\"\n";
    print OMSHELL "create\n";
    closeOMSHELL($actionNum)
}

# All passed by value
sub removeHostInDHCPDLeases {
    my ($mac, $actionNum) = @_;
    openOMSHELL($mac);
    print OMSHELL "open\n";
    print OMSHELL "remove\n";
    closeOMSHELL($actionNum)
}

# All passed by value
sub changeIpInDHCPDLeases {
    my ( $mac, $ip, $actionNum ) = @_;
    $ip = "$NETWORK$ip";
    openOMSHELL($mac);
    print OMSHELL "open\n";
    print OMSHELL "unset ip-address\n";
    print OMSHELL "set ip-address = $ip\n";
    print OMSHELL "update\n";
    closeOMSHELL($actionNum)
}

# All passed by value
sub rndcsync {
    say
        "* Sync changes in the journal file for a dynamic zone to the master file. The journal file is also removed";
    say "Change can take a little moment";
    say
        "If there is a problem, you can try resynchronize with command `below'";
    my @args = ( "rndc", "-k", "/etc/rndc.key", "-p", "953", "-s", "$DNS_SERVER_PRIMARY", "freeze" );
    say "Perform @args";
    system(@args) == 0
        or die "system @args failed: $?";
    @args = ( "rndc", "-k", "/etc/rndc.key", "-p", "953", "-s", "$DNS_SERVER_PRIMARY", "thaw" );
    say "Perform @args";
    system(@args) == 0
        or die "system @args failed: $?";
    say "Success.";
}

# All passed by value
sub nsupdateRemoveAddr {

    my ( $actionNum, $ipUsedRef, $hostnameUsedRef, $index, $sshdhcp, $sshdns ) = @_;
    my @ipUsed       = @$ipUsedRef; my @hostnameUsed = @$hostnameUsedRef;
    # my @ipDNS = split( /\./, $ipUsed[$index] );
    
    say "* Submit Dynamic DNS Update requests. Remove host from zone…";
    
    # For somthing a little bit less verbose, delete debug
    # my $args = "nsupdate -v -p 53 -k /etc/rndc.key"; #  Doesn't work with Marionnet
    my $args = "nsupdate" ;  # For Marionnet
    say "Perform $args";

    # Doesn't work with Marionnet
    # open( NSUPDATE, "|$args" )
    #     || die("Unable to open nsupdate\n");

    my $dnsnsupdate = "/tmp/dnsnsupdate.tmp";
    open( NSUPDATE, ">", $dnsnsupdate )
        or die "Cannot open file ".$dnsnsupdate." for write.\n";
    print NSUPDATE "nsupdate -k /etc/bind/ns-imss-org_rndc-key << EOF \n"; # For Marionnet
    # print NSUPDATE "server $DNS_SERVER_PRIMARY 53\n"; # Doesn't work with Marionnet
    print NSUPDATE "server 127.0.0.1\n"; # For Marionnet
    print NSUPDATE "debug yes\n";
    if ( $actionNum =~ /^[24]$/ ) {
        print NSUPDATE "update delete $hostnameUsed[$index].$DNS_ZONE A\n";
        print NSUPDATE "send\n";
        print NSUPDATE "update delete $hostnameUsed[$index].$DNS_ZONE TXT\n";
        print NSUPDATE "send\n";
    }
    print NSUPDATE "update delete $ipUsed[$index].$DNS_REVERSE_ZONE PTR\n";
    print NSUPDATE "send\n";
    print NSUPDATE "quit\n";
    print NSUPDATE "EOF\n"; # For Marionnet
    close(NSUPDATE) || die "Unable to close nsupdate.\n"; # IF ISN'T WITH MARIONNET, COMMENT THIS LINE
    # if ( $? gt 0 ) {
    #     warn "`nsupdate' closed with error $?.\nScript aborted";
    #     exit 10;
    # }
    #SSH for marionnet
    $sshdns->scp_put ( { glob => 1 },
        "$dnsnsupdate", "$dnsnsupdate" )
            or die "scp failed: " . $sshdns->error;
    my @args = ("bash", "$dnsnsupdate", "&&", "rm", "-f", "$dnsnsupdate");
    say "Perform @args";
    my $sshdnsresult = $sshdns->capture(@args);
    $sshdns->error and
        die "remote command @args failed: " . $sshdns->error;
    say $sshdnsresult;
    unlink $dnsnsupdate;
    say "success";

    # Not usefull
    # $sshdhcp->system("$DHCP_COMMAND_RESTART")
    #     or warn
    #     "Failed to start IPv4 DHCP server. Please, manually restart DHCP server.";



    rndcsync;
}

# All passed by value
sub mysqlQuery {
    my ($dbh, $list, $sqlPrepare) = @_;
    say "* Perform mysql query…";
    say "$sqlPrepare";
    my $sth        = $dbh->prepare($sqlPrepare);
    $sth->execute(@$list);
    say $sth->rows . " row affected";
    if ( $sth->rows lt 1 ) {
        warn
            "No row affected by mysql query in $MYSQL_DATABASE.$MYSQL_TABLE ?. Error.\nScript aborted.";
        exit 15;
    }
    say "Success.";
}

sub confirmModification {
    my $continueSubroutine;
    do {
        say "Are you sure you want to continue [y/n]?";
        chomp ($continueSubroutine=<STDIN>);
    } while ( $continueSubroutine !~ /^[yYnN]$/ );
    if ( $continueSubroutine =~ /^[yY]$/) {
        say "Perform modifications…";
        return 1;
    }
    else {
        say "Nothing done.";
        return 0;
    }
}

sub isArrayEmpty {
    my ($array) = @_;
    if ($#$array lt 0) {
        say "Error, empty list. You cannot perform any action if there is no host saved.";
        return 1;
    }
    else {
        return 0;
    }
}


#-------------------------------------------------------------------------------
#  Subroutines delete and push $macUsed[$index], $ipUses[$index], $hostname[$index] values
#-------------------------------------------------------------------------------

# Add new informations into tabs, to have it into section « Change ip address »  or « Remove ip address »
sub pushNewHostInArray {
    my ($macUsed, $ipUsed, $hostnameUsed, $macNew, $ipNew, $hostnameNew) = @_;
    # http://stackoverflow.com/questions/33359852/perl-modifying-reference-array-via-push-in-subroutine
    # Do not push onto lexical (local) variable $macUsed, but onto the references array
    push @{$_[0]},      $macNew;
    push @{$_[1]},       $ipNew;
    push @{$_[2]}, $hostnameNew;
}

sub deleteOldHostInArray {
    my ($macUsed, $ipUsed, $hostnameUsed, $macNew, $ipNew, $hostnameNew, $index) = @_;
    splice(@{$_[0]}, $index, 1);
    splice(@{$_[1]}, $index, 1);
    splice(@{$_[2]}, $index, 1);
}

#-------------------------------------------------------------------------------
#  Subroutine insert new host {{{1
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
#  Subroutine perform insertion {{{2
#-------------------------------------------------------------------------------
# All passed by value
sub insertValueInMysqlAndDhcp {

    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $macNew, $ipNew, $hostnameNew, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;

    say "\n* Create new host…";
    defineConstanteUsable (\@macUsed, \$macNew, "isMac(\$\$constant)", "mac");
    defineConstanteUsable (\@ipUsed, \$ipNew, "isIpNewValidIp(\$\$constant)", "host ip (e.g. 132)");
    defineConstanteUsable (\@hostnameUsed, \$hostnameNew, "isHostname(\$\$constant)", "hostname");

    say "Attempting add host with mac $macNew, ip $ipNew and hostname $hostnameNew…";

    return 1 if (!confirmModification);

    createHostInDHCPDLeases( $macNew, $ipNew, $hostnameNew, $actionNum );

    my @list = ( $macNew, $ipNew, $hostnameNew );
    my $sqlPrepare = "INSERT INTO $MYSQL_DATABASE.$MYSQL_TABLE VALUES (?, ?, ?)";
    mysqlQuery($dbh, \@list, $sqlPrepare);

    pushNewHostInArray($_[0], $_[1], $_[2], $macNew, $ipNew, $hostnameNew);
    say "\n";

    rndcsync;
}

# #-------------------------------------------------------------------------------
#  Subroutine transform new leases as fix-address. {{{2
#-------------------------------------------------------------------------------


# All passed by value
sub actionInsertFromdhcpdleasesFile {

    # TODO test this function. Not usefull for this project.
    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $sshdhcp, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;

    my $dhcpdleasestmp = "/tmp/dhcpd.leases.tmp";
    $sshdhcp->scp_get( { glob => 1 },
        '/var/lib/dhcp/dhcpd.leases', "$dhcpdleasestmp" )
            or die "scp failed: " . $sshdhcp->error;

    say "\ndhcpcd.leases manpage:
    « The lease file is a log-structured file - whenever a lease changes, the contents of that lease are written to the end of the file. This means that it is entirely
    possible and quite reasonable for there to be two or more declarations of the same lease in the lease file at the same time. In that case, the instance of that
    particular lease that appears last in the file is the one that is in effect. »
    \nAnalysis lease file…";

    my $leases = Net::ISC::DHCPd::Leases->new( file => "$dhcpdleasestmp" );

    # parse leases file, and perform action for each lease who has « active » statut.
    $leases->parse;
    for my $lease ( $leases->leases ) {
        if ( $lease->state eq "active" ) {
            my $macLease      = $lease->hardware_address;
            my $ipLease       = $lease->ip_address;
            my $hostnameLease = $lease->client_hostname;
            # Very verbose, but it's beautifull for programm demonstration.
            say "Ip maybe actually in lease : $ipLease. The lease is for the host $macLease.";
            # Usefull for Archlinux
            if ( $hostnameLease eq "" ) {
                warn "This computer hasn't send some client-hostname, please configure ip client hostname or / and it dhcp client (for dhclient, see option « send host-name ») then restart twice your dhcpd server. Fatal error.\n Script aborted";
                exit 6;
            }
            my $performUpdateStaticIpAndMysql = 1;
            foreach my $n (@macUsed) {
                if ( $n eq $macLease ) {
                    say "This host is already saved into mysql database, therefore it is also saved in DHCP lease database as static ip.";
                    $performUpdateStaticIpAndMysql = 0;
                    last;
                }
            }
            if ($performUpdateStaticIpAndMysql) {
                # If host is alive, it keeps his bnd name and ip.
                # WARNING, WITH MARIONNET, WE CAN'T ACCESS REMOTE HOST with 192.168. Maype try with a router. TODO
                # my $ip_ping    = $ipUsed[$index];
                # my $p          = Net::Ping->new();
                # $host_alive = 1 if $p->ping("$NETWORK$ip_ping");
                # $p->close();

                # if ($host_alive) {
                #     warn "$ip_ping is alive. Disconnect computer client with name $hostnameUsed[$index] and mac $macKey before deleting from DHCPD lease and Mysql database. Fatal error.\nScript aborted";
                #     exit 9;
                # }
                insertValueInMysqlAndDhcp($_[0], $_[1], $_[2], $dbh, $macLease, $ipLease, $hostnameLease, $actionNum);
            }
        }
    }
    unlink $dhcpdleasestmp;
}

#-------------------------------------------------------------------------------
#  Subroutine create new client from scratch {{{2
#-------------------------------------------------------------------------------
# All passed by value
sub createHost {
    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $sshdhcp, $macNew, $ipNew, $hostnameNew, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;
    insertValueInMysqlAndDhcp($_[0], $_[1], $_[2], $dbh, $macNew, $ipNew, $hostnameNew, $actionNum);
}
#-------------------------------------------------------------------------------
#  Subroutine change ip address {{{1
#-------------------------------------------------------------------------------

# All passed by value
sub changeIp {

    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $sshdhcp, $sshdns, $macKey, $ipNew, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;

    say "\n* Attribute new ip…";
    return 1 if (isArrayEmpty(\@macUsed));

    defineMacKey(\$macKey, \@macUsed, \@ipUsed, \@hostnameUsed);
    defineConstanteUsable (\@ipUsed, \$ipNew, "isIpNewValidIp(\$\$constant)", "host ip (e.g. 132)");
    my $index = first_index { $_ eq "$macKey" } @macUsed;
    say "Attempting attribute new IP $ipNew for computer client $hostnameUsed[$index], with mac $macKey and current ip $ipUsed[$index]";

    return 1 if (!confirmModification);

    changeIpInDHCPDLeases( $macUsed[$index], $ipNew, $actionNum );
    nsupdateRemoveAddr( $actionNum, \@ipUsed, \@hostnameUsed, $index, $sshdhcp, $sshdns );

    my @list = ( $ipNew, $macKey );
    my $sqlPrepare
        = "UPDATE $MYSQL_DATABASE.$MYSQL_TABLE SET ip = ? WHERE $MYSQL_DATABASE.$MYSQL_TABLE.mac = ?";
    mysqlQuery($dbh, \@list, $sqlPrepare);

    deleteOldHostInArray($_[0], $_[1], $_[2], $macKey, $ipNew, $hostnameUsed[$index], $index);
    pushNewHostInArray($_[0], $_[1], $_[2], $macKey, $ipNew, $hostnameUsed[$index]);
}

#-------------------------------------------------------------------------------
#  Subroutine change hostname {{{1
#-------------------------------------------------------------------------------

# All passed by value
sub changeHostname {

    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $sshdhcp, $sshdns, $macKey, $hostnameNew, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;

    say "\n* Change hostname…";
    return 1 if (isArrayEmpty(\@macUsed));

    defineMacKey(\$macKey, \@macUsed, \@ipUsed, \@hostnameUsed);
    defineConstanteUsable (\@hostnameUsed, \$hostnameNew, "isHostname(\$\$constant)", "hostname");
    my $index = first_index { $_ eq "$macKey" } @macUsed;
    say "Attempting attribute new hostname $hostnameNew for computer client with mac $macKey and current hostname $hostnameUsed[$index]";

    return 1 if (!confirmModification);

    removeHostInDHCPDLeases ( $macKey, $actionNum );
    createHostInDHCPDLeases ( $macKey, $ipUsed[$index], $hostnameNew, $actionNum );
    nsupdateRemoveAddr( $actionNum, \@ipUsed, \@hostnameUsed, $index, $sshdhcp, $sshdns );

    my @list = ( $hostnameNew, $macKey );
    my $sqlPrepare
        = "UPDATE $MYSQL_DATABASE.$MYSQL_TABLE SET hostname = ? WHERE $MYSQL_DATABASE.$MYSQL_TABLE.mac = ?";
    mysqlQuery($dbh, \@list, $sqlPrepare);

    deleteOldHostInArray($_[0], $_[1], $_[2], $macKey, $ipUsed[$index], $hostnameUsed[$index], $index);
    pushNewHostInArray($_[0], $_[1], $_[2], $macKey, $ipUsed[$index], $hostnameNew);
}

#-------------------------------------------------------------------------------
#  Subroutine remove ip {{{1
#-------------------------------------------------------------------------------

# All passed by value
sub deleteHost {

    my ($macUsed, $ipUsed, $hostnameUsed, $dbh, $sshdhcp, $sshdns, $macKey, $actionNum) = @_;
    my @macUsed = @$macUsed; my @ipUsed = @$ipUsed; my @hostnameUsed = @$hostnameUsed;

    say "\n* Delete host…";
    return 1 if (isArrayEmpty(\@macUsed));

    my $host_alive = 0;
    defineMacKey(\$macKey, \@macUsed, \@ipUsed, \@hostnameUsed);
    my $index          = first_index { $_ eq "$macKey" } @macUsed;
    say "Attempting remove host client $hostnameUsed[$index], with mac $macKey and ip $ipUsed[$index]…";

    return 1 if (!confirmModification);


    removeHostInDHCPDLeases( $macUsed[$index], $actionNum );
    nsupdateRemoveAddr( $actionNum, \@ipUsed, \@hostnameUsed, $index, $sshdhcp, $sshdns );

    my @list = ($macKey);
    my $sqlPrepare = "DELETE FROM $MYSQL_TABLE WHERE mac=(?)";
    mysqlQuery($dbh, \@list, $sqlPrepare);

    deleteOldHostInArray($_[0], $_[1], $_[2], $macKey, $ipUsed[$index], $hostnameUsed[$index], $index);
    pushNewHostInArray($_[0], $_[1], $_[2], $macKey, $ipUsed[$index], $hostnameUsed[$index]);
}

#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
#  Start of Main {{{1
#-------------------------------------------------------------------------------
printWelcomToProgramm;
isGoodParametersActions;
isValidAction;
my $actionNum = $ACTIONNUM;
chooseActionNum(\$actionNum) if ($actionNum != 0);

#-------------------------------------------------------------------------------
#  Initialise Mysql and put used values in array. {{{1
#-------------------------------------------------------------------------------

# See http://www.easysoft.com/developer/languages/perl/dbi-debugging.html

# Connect to the database.
# TODO is it protected against injections ? (not important because not passed in parameter)
my $dbh = DBI->connect(
    "DBI:mysql:database=$MYSQL_DATABASE;mysql_embedded_options=--verbose;host=$MYSQL_SERVER",
    "$MYSQL_USER", "$MYSQL_PASSWORD", { 'RaiseError' => 1 }
);

# Defensive programmation. We have tested if there is only alphanumeric caracters.
$MYSQL_USER = $dbh->quote($MYSQL_USER);
$MYSQL_USER = substr $MYSQL_USER, 1, -1;

# Array of mac, hostname and ip used.
my @macUsed      = ();
my @ipUsed       = ();
my @hostnameUsed = ();

# Select * from table, using placeholder
my $sqlPrepare = "SELECT * FROM $MYSQL_TABLE";
my $sth        = $dbh->prepare($sqlPrepare);
$sth->execute();
say "Hosts saved in Mysql database (for class C network ${NETWORK}0) : ";

# fetchrow_arrayrf is the fastest way to fetch data, but I'v chosen dictionary for it clarity.
while ( my $ref = $sth->fetchrow_hashref ) {
    print
        "     mac = $ref->{'mac'}, ip = $ref->{'ip'}, hostname = $ref->{'hostname'}\n";
    push @macUsed,      $ref->{'mac'};
    push @ipUsed,       $ref->{'ip'};
    push @hostnameUsed, $ref->{'hostname'};
}

say "Empty list" if ( $#macUsed lt 0);
say "End of list.";

# http://search.cpan.org/~timb/DBI-1.636/DBI.pm
# When all the data has been fetched from a SELECT statement, the driver will automatically call finish for you. So you should not call it explicitly except.
# $sth->finish;

#-------------------------------------------------------------------------------
#  Open DHCP and DNS server with SSH {{{1
#-------------------------------------------------------------------------------

my $hostdhcp = "$DHCP_USER:$DHCP_PASSWORD\@$DHCP_SERVER";
say "\n* Attempting to connect to $hostdhcp…";

my $sshdhcp = Net::OpenSSH->new($hostdhcp);
$sshdhcp->error
    and die "Couldn't establish SSH connection: " . $sshdhcp->error;
say "Success.";

my $hostdns = "$DNS_USER:$DNS_PASSWORD\@$DNS_SERVER_PRIMARY";
say "\n* Attempting to connect to $hostdns…";

my $sshdns = Net::OpenSSH->new($hostdns);
$sshdns->error
    and die "Couldn't establish SSH connection: " . $sshdns->error;
say "Success.";

#-------------------------------------------------------------------------------
#  Perform actions {{{1
#-------------------------------------------------------------------------------

    my $mac = $MAC; my $ipNew = $IPNEW; my $hostnameNew = $HOSTNAMENEW;

    while ($actionNum ne "A" and $actionNum ne "a") {
        # Only for Debian Wheezy
        say "\n\n* Test if dhcpd and bind9 are running on remotes servers…";
        my @args = "service dhcpd status";
        my $dhcpdstatus = $sshdhcp->capture (@args);
        say "@args on $hostdhcp";
        say $dhcpdstatus;
        $sshdhcp->error and
            die "remote @args command failed (service dhcpd is it started?): " . $sshdhcp->error;
        @args = "service bind9 status";
        my $bindStatut = $sshdns->capture (@args);
        say "@args on $hostdns";
        say $bindStatut;
        $sshdns->error and
            die "remote @args command failed (service bind9 is it started ?): " . $sshdns->error;
        say "Success.";

        SWITCH: {
            if ( $actionNum eq 1 ) {
                createHost(\@macUsed, \@ipUsed, \@hostnameUsed, $dbh, $sshdhcp, $mac, $ipNew, $hostnameNew, $actionNum);
                last SWITCH;
            }
            if ( $actionNum eq 2 ) {
                deleteHost(\@macUsed, \@ipUsed, \@hostnameUsed, $dbh, $sshdhcp, $sshdns, $mac, $actionNum);
                last SWITCH;
            }
            if ( $actionNum eq 3 ) {
                changeIp(\@macUsed, \@ipUsed, \@hostnameUsed, $dbh, $sshdhcp, $sshdns, $mac, $ipNew, $actionNum);
                last SWITCH;
            }
            if ( $actionNum eq 4 ) {
                changeHostname(\@macUsed, \@ipUsed, \@hostnameUsed, $dbh, $sshdhcp, $sshdns, $mac, $hostnameNew, $actionNum);
                last SWITCH;
            }
            if ( $actionNum eq 5 ) {
                actionInsertFromdhcpdleasesFile(\@macUsed, \@ipUsed, \@hostnameUsed, $dbh, $sshdhcp, $actionNum);
                last SWITCH;
            }

        }
        $actionNum = 0; $mac = ""; $ipNew = ""; $hostnameNew = "";

        chooseActionNum(\$actionNum);
    }


#  Close {{{1
#-------------------------------------------------------------------------------

$dbh->disconnect();

say "\n\n—————— End of programm. ——————\n\n";

sub my_handler {
    $dbh->disconnect();
    die "Caught a signal $!\n\n—————— End of programm. ——————\n\n";
}

# vim: set foldmethod=marker foldlevel=0
