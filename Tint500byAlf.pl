package Tint500byAlf;
use strict;
use warnings;
use 5.0028;
use POSIX 'ceil';
use List::Util qw(reduce uniq);
use feature 'say';
use experimental 'signatures';

# core modules
use Getopt::Long;
use English '-no_match_vars';

# non-core modules
use Const::Fast;
use Mojo::IOLoop::Delay;
use Mojo::UserAgent;
use Mojo::JSON 'decode_json';

our $VERSION = '0.9';

my (%param, %cache);

## Configuration constants ##
# $param{u} = 'foobar@foo.bar';
# $param{p} = 'fooBarFooBar Password';
$param{l} = 125;

const my $C_USER_AGENT => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:66.0) Gecko/20100101 Firefox/66.0';
const my $C_MAX_WORKERS => 15;
## End of configuration constants ##

const my $C_REDIRECT => 302;
const my $C_R_OK => 200;
const my $C_RPP => 50;
const my $C_HELP_CONTENT => <<"EOFH";
Usage:
  $PROGRAM_NAME
    -h | --help     : Print this help
    -r | --report   : File with users to report
    -f | --friends  : Inspect friends and check for bots
                      Cannot be used with --report
    -l | --likes    : Number of likes threshold (default = $param{l})
    -u | --user     : Login credentials, user name
    -p | --password : Login credentials, password

    Login credentials are required, but you can setup default
    values editing this script.

EOFH

## URL constants ##
const my %URL => (
  BASE => 'https://500px.com/',
  LOGIN => 'https://500px.com/login',
  SESSION => 'https://api.500px.com/v1/session',
  FRIENDS => 'https://api.500px.com/v1/users/%s/friends?fullformat=1&page=%s&rpp=' . $C_RPP,
  USER => 'https://api.500px.com/v1/users?',
  REPORT => 'https://500px.com/moderate/save',
);

## Error Messages ##
const my %E_ERRORS => (
  E_NO_CSRF_NAME => 'CSRF Token name was not found',
  E_NO_CSRF_VALUE => 'CSRF Token value was not found',
  E_UNSCC_LOGIN => 'Login Json did not return success',
  E_PARSE_AFFECTION => "Could not parse affection: %s",
  E_PARSE_ID => 'User Id could not be parsed',
  E_GET_OPTIONS => 'Error in command line arguments. Use --help.',
  E_MISS => 'Report/Friends argument is required',
  E_NOT_FILE => 'File does not exist',
  E_NO_CREDENTIAL => "Missing credential parameter: %s",
  E_OPEN => "Could not open file %s",
  E_CLOSE => "Could not close file %s",
  E_REP_FR => 'Report/Friends are exclusive options',
  E_UNKNOWKN_OPTION => 'Unknown url option',
  E_BAD_RC => "Bad return code: Recieved %s but %s was expected. Page: %s",
  E_UNK => 'Unknown error',
);

## Functions ##
sub hurt($which, @extraParameters) {
  die $E_ERRORS{E_UNK} . "\n" if ! exists $E_ERRORS{$which};
  die sprintf($E_ERRORS{$which} . "\n", @extraParameters);
}

sub check_parameters {
  if ( ! defined $param{u}
    || ! defined $param{p}
    || ! defined $param{f} && ! defined $param{r}
    ||   defined $param{f} &&   defined $param{r} ) {
    say $C_HELP_CONTENT;
  }

  hurt('E_MISS') if ! defined $param{r} && ! defined $param{f};
  hurt('E_NOT_FILE') if defined $param{r} && ! -f $param{r};
  hurt('E_NO_CREDENTIAL', 'user') if ! defined $param{u};
  hurt('E_NO_CREDENTIAL', 'password') if ! defined $param{p};
  hurt('E_REP_FR') if defined $param{f} && defined $param{r};

  return;
}

sub readUsersFromFile($file) {
  local $RS = undef;
  open my $fh, q(<), $file or hurt('E_OPEN', $file);
  const my $content => <$fh>;
  close $fh or hurt('E_CLOSE', $file);
  return $content =~ m{ ^ (\S++) (?! .* ^ \1 $) }sxmg
}

sub parseCsrfData($tx) {
  const my $dom => $tx->res->dom;

  const my $csrfName =>
    $dom->at('meta[name="csrf-param"]')->attr('content');

  const my $csrfToken =>
    $dom->at('meta[name="csrf-token"]')->attr('content');

  hurt('E_NO_CSRF_NAME') if ! $csrfName;
  hurt('E_NO_CSRF_VALUE') if ! $csrfToken;

  return { param => $csrfName, token => $csrfToken };
}

sub parseAffection($tx) {
  # Parsing with regex for performance reasons.
  $tx->res->to_string() =~ m/\bThis[ ]user[ ](liked[^']+)/sxmi
    or hurt('E_PARSE_AFFECTION', 'Full affection string');

  const my $title => $1 =~ s/(?<=\d)[.](?=\d)|[.]$//sxmrg;

  hurt('E_PARSE_AFFECTION', $title)
    if $title !~ m{ (\d+) \D++ (\d+) }sxmg;

  return { day => $1, week => $2, title => $title };
}

sub parseUserId($tx) {
  hurt('E_PARSE_ID') if $tx
    ->res->dom->at('meta[property="al:ios:url"]')
    ->attr('content') !~ m{ /user/ (\d++) }isxmg;

  return $1;
}

sub userNameFromUrl($tx) {
  return $tx->req->url->path->to_string =~ s{^/}{}sxmir;
}

sub setupUserTickets(@users) {
  return map { {action => 'getUser', user => $_} } @users;
}

sub setupFriendsTickets($friendsPages) {
  return map { {action => 'getFriends', num => $_ } }
    (1 .. $friendsPages);
}

sub setupUA {
  const my $ua => Mojo::UserAgent->new;
  $ua->transactor->name($C_USER_AGENT);
  $ua->max_redirects(0);
  $ua->proxy->http($ENV{'HTTP_PROXY'});
  $ua->proxy->https($ENV{'HTTPS_PROXY'} // $ENV{'HTTP_PROXY'});
  return $ua;
}

# Process urls actions (tickets) with a limit on max workers
sub processUrl ($delay, $ua, $workers, $tickets) {
  return if ${$workers} < 1 || @{$tickets} < 1;
  const my $ticket => shift @{$tickets};
  ${$workers}--;
  const my $end => $delay->begin();
  const my $onReturn => sub {
    ${$workers}++;
    processUrl($delay, $ua, $workers, $tickets);
    &{$end};
  };

  if ($ticket->{action} eq 'getUser') {
    $ua->get($URL{BASE} . $ticket->{user} => $onReturn);
  }
  elsif ($ticket->{action} eq 'postReport') {
    const my $postData => {
      reported_item_type => 1,
      reported_item_id   => $ticket->{id},
      reason             => 2
    };
    $ua->post($URL{REPORT}
      => {'X-CSRF-Token' => $cache{csrf}}
      => form => $postData => $onReturn);
  }
  elsif ($ticket->{action} eq 'getFriends') {
    $ua->get(
      sprintf($URL{FRIENDS}, $cache{userid}, $ticket->{num})
      => {'X-CSRF-Token' => $cache{csrf}}
      => $onReturn);
  }
  else {
    hurt('E_UNKNOWKN_OPTION');
  }

  return;
}

sub processTickets($delay, $uagent, @tickets) {
  my $workers = $C_MAX_WORKERS;
  foreach (1 .. $C_MAX_WORKERS) {
    processUrl($delay, $uagent, \$workers, \@tickets);
  }
  return;
}

sub printTxError($tx) {
  $tx->error->{code}
    and printf " ->Error Code: %s\n", $tx->error->{code};

  $tx->error->{message}
    and printf " ->Error Message: %s\n", $tx->error->{message};

  return;
}

sub showError($error) {
  say {*STDERR} "ERROR --> $error";
  exit 1;
}

sub evalRc($tx, $rc, $reason = undef) {
  # Evals RC. If reason is given then it dies
  return $tx->res->code == $rc if ! defined $reason;
  hurt('E_BAD_RC', $tx->res->code, $rc, $reason)
    if $tx->res->code != $rc;
  return;
}

sub tooManyLikes($affection) {
  return $affection->{day} >= $param{l}
    || $affection->{week} / 7 >= $param{l};
}

############
### MAIN ###
############

GetOptions ('r|report=s'   => \$param{r},
            'f|friends'    => \$param{f},
            'l|likes=s'    => \$param{l},
            'u|user=s'     => \$param{u},
            'p|password=s' => \$param{p},
            'h|help'       => \$param{h})
  or hurt('E_GET_OPTIONS');

if ($param{h}) {
  say $C_HELP_CONTENT;
  exit 0;
}

check_parameters();

const my $uagent => setupUA();

Mojo::IOLoop::Delay->new()->steps(
  ## Get Login Page
  sub ($delay) {
    say 'Please wait...';
    $uagent->get($URL{LOGIN} => $delay->begin(0));
    return;
  },

  ## Post Login and pass csrf token
  sub ($delay, $ua, $tx) {
    evalRc($tx, $C_R_OK, 'getLogin');

    const my $csrfData => parseCsrfData($tx);

    const my $data => {
      'session[email]'     => $param{u},
      'session[password]'  => $param{p},
      $csrfData->{param} => $csrfData->{token}
    };

    $ua->post($URL{SESSION}
      => form => $data
      => $delay->begin(1));

    $cache{csrf} = $csrfData->{token};
    return;
  },

  # Validate Login, store userId
  sub ($delay, $tx) {
    evalRc($tx, $C_R_OK, 'getSession');

    const my $jsonResponse => decode_json $tx->res->body;
    if ( ! exists $jsonResponse->{success}
      || $jsonResponse->{success} != Mojo::JSON::true) {
      hurt('E_UNSCC_LOGIN');
    }

    $cache{userid} = $jsonResponse->{user}{id};
    return;
  }

)->catch(\&showError)->wait;

## Actions for "Report Users"
const my @actionsReportUsers => (
  ## Get userpages for every user
  sub ($delay) {
    const my @tickets =>
      setupUserTickets(readUsersFromFile($param{r}));

    processTickets($delay, $uagent, @tickets);
    return;
  },

  ## Prepare user cache, prepare tickets, process tickets
  sub ($delay, @txs) {
    foreach my $tx (@txs) {
      const my $user => userNameFromUrl($tx);
      evalRc($tx, $C_R_OK, "getUserPage: $user");

      const my $id => parseUserId($tx);

      $cache{users}{$id}{name}   = $user;
      $cache{users}{$id}{affect} = parseAffection($tx);
    }

    const my @tickets => map {
      { action => 'postReport',
        id     => $_,
        user   => $cache{users}{$_}{user} }
    }
    grep {
      tooManyLikes($cache{users}{$_}{affect});
    }
    keys %{$cache{users}};

    processTickets($delay, $uagent, @tickets);
    $delay->pass();
    return;
  },

  ## Print results
  sub ($delay, @txs) {
    foreach my $tx (@txs) {
      const my $id => $tx->req->param('reported_item_id');
      const my $user => $cache{users}{$id}{name};
      const my $likes => $cache{users}{$id}{affect}{title};

      if (evalRc($tx, $C_REDIRECT)) {
        say "User $user was reported successfully ($likes)";
      }
      else {
        say "WARNING: Could not report user $user";
        $tx->error and printTxError($tx);
      }
    }
    say 'Finished reporting users.';
    return;
  },
);

const my @actionsBotFriends => (
  # Get Friends number
  sub ($delay) {
    $uagent->get($URL{USER}
      => {'X-CSRF-Token' => $cache{csrf}}
      => $delay->begin());
    return;
  },

  # Get friends
  sub ($delay, $tx) {
    evalRc($tx, $C_R_OK, 'getSelfUser');
    const my $json => decode_json($tx->res->body);

    const my $friendPages =>
      ceil($json->{user}{'friends_count'} / $C_RPP);

    const my @tickets => setupFriendsTickets($friendPages);
    processTickets($delay, $uagent, @tickets);
    return;
  },

  # Get user pages
  sub ($delay, @txPages) {
    const my $friends => reduce {
      evalRc($b, $C_R_OK, 'PageFriends');
      my $body = $b->res->body =~ s/[^\x00-\x7F]//sxmgr;
      my $json = decode_json($body);
      my @mod = (@{$a}, @{$json->{friends}});
      return \@mod;
    } ([], @txPages);

    const my @friends =>
      uniq map { $_->{username} } @{$friends};

    const my @RWtickets => setupUserTickets(@friends);
    processTickets($delay, $uagent, @RWtickets);
    return;
  },

  # Report friends
  sub ($delay, @txFriends) {
    foreach my $tx (@txFriends) {
      evalRc($tx, $C_R_OK, 'getUserPage');
      const my $affect => parseAffection($tx);
      if (tooManyLikes($affect)) {
        printf "%s %s\n"
          , $URL{BASE} . userNameFromUrl($tx)
          , $affect->{title};
      }
    }
    say 'Finished inspecting friends.';
    return;
  },
);

Mojo::IOLoop::Delay->new()->steps(
  $param{f} ? @actionsBotFriends : @actionsReportUsers
)->catch(\&showError)->wait;

1;
