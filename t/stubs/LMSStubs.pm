package LMSStubs;

# Compile-time environment for `perl -c` outside a running LMS.
# slimserver.pl defines DEBUGLOG/INFOLOG/SCANNER/WEBUI as main:: constants before any
# plugin is compiled, so `main::DEBUGLOG && ...` is a legal bareword in a real
# server and a syntax error anywhere else. Not a bug in the plugin.

BEGIN {
    *main::DEBUGLOG = sub () { 0 };
    *main::INFOLOG  = sub () { 0 };
    *main::SCANNER  = sub () { 0 };
    *main::WEBUI    = sub () { 1 };
    *main::ISWINDOWS = sub () { 0 };
}

1;
