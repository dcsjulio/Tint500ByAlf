# Tint500ByAlf, a 500px bot	

*This Is Not The 500px Bot You Are Looking For*.


## What is it?

A [perl](https://www.perl.org/)/[mojolicious](https://mojolicious.org/) script for reporting users that use automated tools for liking photos.

> More than 1000 likes in a day? Really?

## Modes of working

You can check & [report](https://support.500px.com/hc/en-us/articles/204700337-How-do-I-report-a-photo-user-comment) all the users inside a given file or inspect your friends and tell which ones look like bots.

For both actions there's a number of likes threshold (125 by default). You can change it with the `-l | --likes` parameter.

The threshold is used for both likes in a day and likes in a week divided by seven.

## User credentials

You can use the folloging parameters:

    -u | --user
    -p | --password

or edit the script and uncomment and modify the following lines:

    ## Configuration constants ##
    # $params{u} = 'foobar@foo.bar';
    # $params{p} = 'fooBarFooBar Password';

## Usage parameters

    Usage:
      .\Tint500byAlf.pl
        -h | --help     : Print this help
        -r | --report   : File with users to report
        -f | --friends  : Inspect friends and check for bots
                          Cannot be used with --report
        -l | --likes    : Number of likes threshold (default = 125)
        -u | --user     : Login credentials, user name
        -p | --password : Login credentials, password
    
        Login credentials are required, but you can setup default
        values editing this script.

## Troubleshooting

On windows machines, the script may be slow and you may recieve timeouts.

For fixing this, add an exclussion to the Windows Defender, exclussion type `process` and select the path of the `perl` executable.
