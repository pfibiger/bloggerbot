#!/usr/bin/perl
#
#bloggerbot.pl, a public aim->blogger gateway / posting service
#http://www.fibiger.org/bloggerbot/
#
#by Philip Fibiger : http://www.fibiger.org : philip@fibiger.org
#with Jeremy Muhlich : http://www.acm.jhu.edu/~jmuhlich : jmuhlich@bitflood.org
#
#version 1.16

use Net::AOLIM;
use RPC::XML;
use RPC::XML::Client;
use DBD::mysql;
use IO::Handle;
use XML::Simple;
use strict;
use vars qw($IM_ERR);

my $config = XMLin(new IO::File($ARGV[0] || 'bloggerbot.xml'));
my $config_db = $config->{database};
my $config_blogger = $config->{blogger};
my $config_aim = $config->{aim};
my $config_logs = $config->{logs};
my $debug = $config->{debug}{level};

my ($aim, %handlers);
my @message_queue = ();
my $msg_counter = 0;
my $oldtime;
my $delay = 5;

my $dbh = DBI->connect("dbi:mysql:database=$config_db->{name};host=$config_db->{host}",
		       $config_db->{user}, $config_db->{password})
    or die "Can't log in to database.";

my $blogger_app_key		= $config_blogger->{appkey};
my $blogger_xmlrpc_client	= new RPC::XML::Client "http://$config_blogger->{host}:$config_blogger->{port}$config_blogger->{path}";

%handlers = (
#	'CONFIG' => \&on_config,
	     'IM_IN'  => \&on_im,
	     'ERROR'  => \&on_error,
	     'EVILED' => \&on_eviled,
	     );

$aim = Net::AOLIM->new("username" => $config_aim->{screenname}, 
		       "password" => $config_aim->{password},
		       "callback" => \&callback,
		       "allow_srv_settings" => 0,
		       "login_timeout" => 2 );

my %banned;

open(BLOCKS, "eviled_blocklist");
my @to_block = <BLOCKS>;
close BLOCKS;

chomp @to_block;
@banned{@to_block} = (1) x @to_block;


#$aim->im_permit_all();
#foreach my $block (@to_block) {
#	$aim->im_deny($aim->norm_uname($block)) 
#}

$aim->add_buddies("friends", $config_aim->{screenname});
if (!defined($aim->signon())) {
    print STDERR "SIGNON ERROR: $IM_ERR\n";
    exit(1);
}

$debug and print STDERR "\n\n\n==========\nSTARTUP\n==========\n\n\n";

open(SENDLOG , ">>$config_logs->{send}");
autoflush SENDLOG 1;
$| = 1;
print SENDLOG scalar(localtime()), " ====================\n";

$oldtime = time();
while (1) {
    $debug >= 5 and print STDERR ">>>> LOOP BEGIN\n";
    $aim->ui_dataget(.25);
    if (@message_queue and time() >= $oldtime + $delay) {
	my $im = shift(@message_queue);
	log_send($im, '-');
	my $msg = "[LOAD:".$im->{load}."]\n".$im->{message};
	$aim->toc_send_im($im->{name}, $msg);
	$oldtime = time();
    }
    $debug >= 5 and print STDERR ">>>> LOOP END\n";
}


sub callback {
    my ($response, @args) = @_;
    my ($handler);

    $debug >= 2 and print "##$response##", join("::", @args), "##\n";
    $handler = $handlers{$response};
    $handler->(@args) if $handler;
}

#sub on_config {
#	my ($str) = @_;
#
#	$self->set_config_str($str, 1);
#}

sub on_error {
    my ($error, @stuff) = @_;

    #$errstr =~ s/\$(\d+)/$stuff[$1]/ge;
    $debug and print STDERR "ERROR: $error\n";
}

sub on_eviled {
    my ($level, $from) = @_;
    $from = $aim->norm_uname($from);
    $debug and print STDERR "WARNED BY: $from ...the fucker";
    $aim->toc_evil($from);
    #$aim->add_im_deny($from);
    
    open (TOWRITE, ">>eviled_blocklist");
    print TOWRITE "$from\n";
    close TOWRITE;
    
    $banned{$from} = 1;
}

sub on_im {
    my ($from, $friend, $msg) = @_;
    my ($to_post);
    $from = $aim->norm_uname($from);
    $to_post = $msg;
    $msg =~ s/<[^>]+>//g;
    $msg =~ s/^\s+//g;
    $to_post =~ s/<html(.*?)>//gi;
    $to_post =~ s/<\/html>//gi;
    $to_post =~ s/<body(.*?)>//gi;
    $to_post =~ s/<\/body>//gi;
    $to_post =~ s/<font(.*?)>//gi;
    $to_post =~ s/<\/font>//gi;
    $to_post =~ s/\&lt\;/\</gi;
    $to_post =~ s/\&rt\;/\>/gi;
    $to_post =~ s/\<a href\=[\',\"]\<A HREF\=.*?\"\>/\<a href\=\"/i;
    $to_post =~ s/\<\/A\>\[',"]\>/\"\>/i;

	$debug and print STDERR "incoming message::$from:$msg\n";

        if (exists $banned{$from}) {
                print "BANNED USER $from tried to talk to us. bah.\n";
        }
	else {

	if (substr($msg,0,1) eq "\/") {
		my @commands = split(" ", $msg);
		if ($commands[0] eq "/help") {
			send_help($from);
		}
		elsif ($commands[0] eq "/register") {
			if ($#commands  == 2) {
				register($from, $commands[1], $commands[2]);
			}
			else {
				my ($full_login, $i);
				for ($i=1; $i<$#commands; $i++) {
				 $full_login .= "$commands[$i] ";
				}
				register($from, $full_login, $commands[$#commands]);
			}		
		}
		elsif ($commands[0] eq "/password") {
			change_password($from, $commands[1]);
		}
		elsif ($commands[0] eq "/list") {
			list_blogs($from);
		}
		elsif ($commands[0] eq "/default") {
			set_default($from, $commands[1]);
		}
		elsif ($commands[0] eq "/update") {
			update($from);
		}
		elsif ($commands[0] eq "/lastfive") {
			lastfive($from);
		}
		elsif ($commands[0] eq "/delete") {
			deletepost($from, $commands[1]);
		}
		else {
			send_im($from, "that isn't a valid command. use /help for syntax help");
		}
	}
	else {
		my @member = is_member($from);
		if ($member[0] eq "") {
			send_im($from, "you currently aren't registered. use /help for syntax help");
		}
		elsif (!has_default($from)) {
			send_im($from, "please set a default weblog. /default BLOGID, use /list to see ids");
		}
		else {
			my $sqlfind = "SELECT u.nick, u.blogname, u.password, b.blogid FROM users u, blogs b WHERE u.nick='$from' AND u.id=b.userid AND b.defaultblog='Y'";
			my $sthfind = $dbh->prepare($sqlfind) || die "DB prepare error";
			$sthfind->execute || die "DB execute error";
			my @rowfind = $sthfind->fetchrow_array();
			$sthfind->finish;

			my $blogger_xmlrpc_request = new RPC::XML::request(
				"blogger.newPost",
				RPC::XML::string->new($blogger_app_key),
				RPC::XML::string->new($rowfind[3]),
				RPC::XML::string->new($rowfind[1]),
				RPC::XML::string->new($rowfind[2]),
				RPC::XML::string->new($to_post),
				RPC::XML::boolean->new("true")
			);
			my $blogger_xmlrpc_response = $blogger_xmlrpc_client->send_request($blogger_xmlrpc_request);
			$debug >= 4 and print STDERR "RESPONSE [$blogger_xmlrpc_response], REF [".ref($blogger_xmlrpc_response)."]\n";	
			if (!ref($blogger_xmlrpc_response)) {
				send_im($from, "xml-rpc server error. try again in a few seconds");
			}
			else {
				my $blogger_reply = $blogger_xmlrpc_response->value->value;
				if ($blogger_xmlrpc_response->is_fault) {
					send_im($from, "unable to post: $blogger_reply->{'faultCode'} : $blogger_reply->{'faultString'}");
				}
				else {
###					send_im($from, "$blogger_reply posted successfully");	
				}
			}	
		}
	}
	}
}

sub is_member {
    my @params = @_;
    my ($sql, $sth, @row);

    $sql = "SELECT u.nick, u.blogname, u.password, b.blogid FROM users u, blogs b WHERE u.nick='$params[0]' AND u.id=b.userid";
    $sth = $dbh->prepare($sql) || die "DB prepare error";
    $sth->execute || die "DB execute error";
    @row = $sth->fetchrow_array();
    $sth->finish;
    if ($row[0] eq "") {
	return ("","","","");
    }
    else {
	return ($row[0],$row[1], $row[2], $row[3]);
    }
}

sub has_default {
    my @params = @_;
    my ($sql, $sth, @row);

    $sql = "SELECT b.blogid FROM users u, blogs b WHERE u.nick='$params[0]' AND u.id=b.userid  AND b.defaultblog='Y'";
    $sth = $dbh->prepare($sql) || die "DB prepare error";
    $sth->execute || die "DB execute error";
    @row = $sth->fetchrow_array();
    $sth->finish;
    if ($row[0] eq "") {
	return (0);
    }
    else {
	return (1);
    }
}

sub send_help {
    my @params = @_;

    #/password BLOGGERPASS sets the password needed to publish\n
    send_im($params[0], <<HELP_MESSAGE);
    just type into the aim window to post, or use these commands:
    /register BLOGGERNAME PASSWORD registers your screenname with a particular blogger login
	/list will give you a listing of all blogs you can publish to
	    /default BLOGIDNUM will set the blog that you are currently publishing to
		/update will refresh the list of blogs you are a member of
		    /lastfive will return post id numbers and the first few words of your last five posts
			/delete POSTIDNUM will delete the post that you specify
			    HELP_MESSAGE
			    }

sub register {
    my @params = @_;
    my @member = is_member($params[0]);

    if ($member[0] eq "") {
	my $blogger_xmlrpc_request = new RPC::XML::request(
							   "blogger.getUsersBlogs",
							 RPC::XML::string->new($blogger_app_key),
							 RPC::XML::string->new($params[1]),
							 RPC::XML::string->new($params[2])
							   );
	my $blogger_xmlrpc_response = $blogger_xmlrpc_client->send_request($blogger_xmlrpc_request);
	$debug >= 4 and print STDERR "RESPONSE [$blogger_xmlrpc_response], REF [".ref($blogger_xmlrpc_response)."]\n";
	if (!ref($blogger_xmlrpc_response)) {
	    send_im($params[0], "xml-rpc server error. try again in a few seconds");
	}
	else {
	    my $reply = $blogger_xmlrpc_response->value->value;

	    if ($blogger_xmlrpc_response->is_fault) {
		send_im($params[0], "error registering. please make sure your username and password are correct");
	    }
	    else {
		my $aim_nick = quotemeta($params[0]);
		my $blogger_login = quotemeta($params[1]);
		my $sql = "INSERT INTO users (id, blogname, nick, password) values(0, '$blogger_login', '$aim_nick', '$params[2]')";
		my $sth = $dbh->prepare($sql) || die "DB prepare error";
		$sth->execute || die "DB execute error";
		my $insert_id = $sth->{'mysql_insertid'};
		$sth->finish;
		
		foreach my $elt (@$reply) {
		    my $blog_name = $elt->{'blogName'};
		    #$blog_name =~ s/\'//gi;
		    #$blog_name =~ s/\"//gi;
		    $blog_name = quotemeta($blog_name);
		    my $sqleach = "INSERT INTO blogs (userid, blogid, blogdesc, defaultblog) values($insert_id, $elt->{'blogid'}, '$blog_name', 'N')";
		    my $stheach = $dbh->prepare($sqleach) || die "DB prepare error";
		    $stheach->execute || die "DB execute error";
		    $stheach->finish;
		}
		send_im($params[0], "you are now registered! select your default blog from /list, set it with /default, and start posting");	
	    }
	}
    }
    else {
	send_im($member[0], "you are already registered");
    }
}

sub change_password {
}

sub list_blogs {
    my @params = @_;
    my @member = is_member($params[0]);

    if ($member[0] eq "") {
	send_im($params[0], "you currently aren't registered. use /help for syntax help");
    }
    else {
	my $sql = "SELECT b.blogid, b.blogdesc, b.defaultblog from users u, blogs b WHERE u.id=b.userid AND u.nick='$params[0]'";
	my $sth = $dbh->prepare($sql) || die;
	$sth->execute || die;
	my $str_to_send = "Current blogs: (use /update to get new list of blogs, Y denotes default blog)\n\n";
	while (my @rows = $sth->fetchrow_array()) {
	    $str_to_send .= $rows[0] . "   " . $rows[1] . "   " . $rows[2] . "\n";
	}
	$sth->finish;
	send_im($params[0], "$str_to_send");
    }
}

sub set_default {
    my @params = @_;
    my @member = is_member($params[0]);

    if ($member[0] eq "") {
	send_im($params[0], "you currently aren't registered. use /help for syntax help");
    }
    else {
	my $quotedblogid = quotemeta($params[1]);
	my $sql = "SELECT b.blogid, u.id from blogs b, users u WHERE b.blogid='$quotedblogid' AND b.userid=u.id AND u.nick='$params[0]'";
	my $sth = $dbh->prepare($sql) || die;
	$sth->execute || die;
	my @row = $sth->fetchrow_array();
	$sth->finish;
	if ($row[0] eq "") {
	    send_im($params[0], "invalid blog id number. please check it and try again");
	}
	else {
	    my $sql = "UPDATE blogs SET defaultblog='N' WHERE userid=$row[1]";
	    my $sth = $dbh->prepare($sql) || die;
	    $sth->execute || die;
	    $sth->finish;
	    $sql = "UPDATE blogs SET defaultblog='Y' WHERE userid=$row[1] AND blogid=$row[0]";
	    $sth = $dbh->prepare($sql) || die;
	    $sth->execute || die;
	    $sth->finish;
	    send_im($params[0], "blog $row[0] set as default");
	}
    }
}

sub update {
    my @params = @_;
    my @member = is_member($params[0]);
    if ($member[0] eq "") {
	send_im($member[0], "you are not registered");
    }
    else {
	my $blogger_xmlrpc_request = new RPC::XML::request(
							   "blogger.getUsersBlogs",
							 RPC::XML::string->new($blogger_app_key),
							 RPC::XML::string->new($member[1]),
							 RPC::XML::string->new($member[2])
							   );
	my $blogger_xmlrpc_response = $blogger_xmlrpc_client->send_request($blogger_xmlrpc_request);
	$debug >= 4 and print STDERR "RESPONSE [$blogger_xmlrpc_response], REF [".ref($blogger_xmlrpc_response)."]\n";
	if (!ref($blogger_xmlrpc_response)) {
	    send_im($params[0], "xml-rpc server error. try again in a few seconds");
	}
	else {
	    my $reply = $blogger_xmlrpc_response->value->value;
	    if ($blogger_xmlrpc_response->is_fault) {
		send_im($params[0], "error updating..contact bloggerbot\@fibiger.org");
	    } 
	    else {
		my $sql = "SELECT u.id from users u WHERE u.nick='$params[0]'";
		my $sth = $dbh->prepare($sql) || die;
		$sth->execute || die;
		my @row = $sth->fetchrow_array();
		my $insert_id = $row[0];
		$sth->finish;

		my $sqldel = "DELETE FROM blogs WHERE userid='$insert_id'";
		my $sthdel = $dbh->prepare($sqldel) || die;
		$sthdel->execute || die;
		$sthdel->finish;
		
		foreach my $elt (@$reply) {
		    my $blog_name = $elt->{'blogName'};
		    #$blog_name =~ s/\'//gi;
		    #$blog_name =~ s/\"//gi;
		    $blog_name = quotemeta($blog_name);
		    my $sqlinsert = "INSERT INTO blogs (userid, blogid, blogdesc, defaultblog) values($insert_id, $elt->{'blogid'}, '$blog_name', 'N')";
		    my $sth2 = $dbh->prepare($sqlinsert) || die;
		    $sth2->execute || die;
		    $sth2->finish;
		}
		send_im($params[0], "blog list updated! to see your blogs type /list, set publishing blog with /default, and start posting");	
	    }
	}
    }
}

sub lastfive {
    my @params = @_;
    my @member = is_member($params[0]);
    my $numposts = 5;
    if ($member[0] eq "") {
	send_im($member[0], "you are not registered");
    }
    elsif (!has_default($params[0])) {
	send_im($params[0], "please set a default weblog. /default BLOGID, use /list to see ids");
    }
    else {
	my $sql = "SELECT b.blogid from blogs b, users u WHERE u.nick='$params[0]' AND u.id=b.userid AND b.defaultblog='Y'";
	my $sth = $dbh->prepare($sql) || die;
	$sth->execute || die;
	my @row = $sth->fetchrow_array();
	my $blog_id = $row[0];
	$sth->finish;
	my $blogger_xmlrpc_request = new RPC::XML::request(
							   "blogger.getRecentPosts",
							 RPC::XML::string->new($blogger_app_key),
							 RPC::XML::string->new($blog_id),
							 RPC::XML::string->new($member[1]),
							 RPC::XML::string->new($member[2]),
							 RPC::XML::int->new($numposts)
							   );
	my $blogger_xmlrpc_response = $blogger_xmlrpc_client->send_request($blogger_xmlrpc_request);
	$debug >= 4 and print STDERR "RESPONSE [$blogger_xmlrpc_response], REF [".ref($blogger_xmlrpc_response)."]\n";
	if (!ref($blogger_xmlrpc_response)) {
	    send_im($params[0], "xml-rpc server error. try again in a few seconds");
	}
	else {
	    my $reply = $blogger_xmlrpc_response->value->value;
	    if ($blogger_xmlrpc_response->is_fault) {
		send_im($params[0], "error getting post list...contact bloggerbot\@fibiger.org");
		print $reply . "\n";
	    }
	    else {
		my $str_to_send = "Last 5 posts in default blog: (use post id numbers to delete posts)\n\n";
		foreach my $elt (@$reply) {
		    my $postid = $elt->{'postid'};
		    my $content = $elt->{'content'};
		    my $abbrev_content = substr($content, 0, 16) . "...";
		    $str_to_send .= $postid . "   " . $abbrev_content . "\n";
		}
		send_im($params[0], "$str_to_send");
	    }
	}
    }
}

sub deletepost {
    my @params = @_;
    my @member = is_member($params[0]);
    my $posttodel = $params[1];
    if ($member[0] eq "") {
	send_im($member[0], "you are not registered");
    }
    elsif (!has_default($params[0])) {
	send_im($params[0], "please set a default weblog. /default BLOGID, use /list to see ids");
    }
    else {
	my $blogger_xmlrpc_request = new RPC::XML::request(
							   "blogger.deletePost",
							 RPC::XML::string->new($blogger_app_key),
							 RPC::XML::string->new($posttodel),
							 RPC::XML::string->new($member[1]),
							 RPC::XML::string->new($member[2]),
							 RPC::XML::boolean->new("true")
							   );
	my $blogger_xmlrpc_response = $blogger_xmlrpc_client->send_request($blogger_xmlrpc_request);
	$debug >= 4 and print STDERR "RESPONSE [$blogger_xmlrpc_response], REF [".ref($blogger_xmlrpc_response)."]\n";
	if (!ref($blogger_xmlrpc_response)) {
	    send_im($params[0], "xml-rpc server error. try again in a few seconds.");
	}
	else {
	    my $reply = $blogger_xmlrpc_response->value->value;
	    if ($blogger_xmlrpc_response->is_fault) {
		send_im($params[0], "possibly an invalid post id number, or you don't have the rights to delete this post. check your post id, and try again.");
		print $reply . "\n";
	    }
	    else {
		send_im($params[0], "post deleted successfully");
	    }
	}
    }
}

sub send_im {
    my ($name, $message) = @_;
    my ($im);

    if (grep {$_->{name} eq $name and $_->{message} eq $message} @message_queue) {
	$debug and print STDERR "DUPE: dropping duplicate outgoing message to $name\n";
	return;
    }

    $im = {
	'name'    => $name,
	'message' => $message,
	'load'    => scalar(@message_queue),
	'id'      => $msg_counter++,
    };
    push @message_queue, $im;
    log_send($im, '+');
}

sub log_send {
    my ($im, $char) = @_;
    my ($fmt);

    if ($char eq '+') {
	$fmt = "%5d %5d      ";
    } else {
	$fmt = "%5d       %5d";
    }

    print SENDLOG scalar(localtime()), " $char ",
    sprintf(" $fmt ", scalar(@message_queue), $im->{id}),
    "$im->{name}\n";
}

