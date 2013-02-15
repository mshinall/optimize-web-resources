#!/usr/bin/perl -w
#
# https://github.com/mshinall
#
# Optimize plain text source code files such as .js and .css

use 5.010_000;

use strict;
use warnings;
use File::Basename;
use File::Copy;
use File::Find;
use File::Path;
use Log::Log4perl;
use Getopt::Long;



my $VERSION = "1.23";
my $script = File::Basename::basename($0);
my $basedir = File::Basename::dirname($0);

my $opt_o = "";
my $opt_r = [];
GetOptions(
    'output|o=s' => \$opt_o,
    'root|r=s@' => \$opt_r,
);

if(scalar(@ARGV) <= 0) {
print<<_END_;

Usage:
    ${script} [-or] SOURCE_ITEMS...

    SOURCE_ITEMS
        One or more files or directories to process. Files are processed as
        single items while directories are processed recursively.
    OPTIONS
        -o  output  Generated files will go to this output directory.
        -r  root    Root directory of source with which to organize the output.
    *Note: See the \$config block in the script for more options.
    
_END_
    exit(1);
}

my $sourceFiles = \@ARGV;

my $config = {
    DEFAULT_OUTPUT_DIR => 'optimized-sources',
    HANDLE_OUTPUT_DIR => 0, #0=leave as is, 1=delete, 2=backup
    LOG_FILE => 'optimize_source.log',
    SYS_ERROR_FILE => 'optimize_source_errors.log',
    EXT_MAP => {
        '.js' => {
            'new_ext' => '.min.js',
            'processor' => "${basedir}/compiler.jar",
            'cmd' => "java -jar ${basedir}/compiler.jar" . 
                     " --compilation_level SIMPLE_OPTIMIZATIONS" .
                     " --warning_level=QUIET" .
                     " --js '\%1\$s'" .
                     " --js_output_file '\%2\$s'",
             'alt_ext' => [
                '-min.js',
             ],
        },
        '.css' => {
            'new_ext' => '.min.css',
            'processor' => "${basedir}/yuicompressor-2.4.2.jar",        
            'cmd' => "java -jar ${basedir}/yuicompressor-2.4.2.jar" .
                     " -o '\%2\$s'" .
                     " '\%1\$s'",
             'alt_ext' => [
                '-min.css',
             ],                     
        },
    },
    MERGE_FILES => 1, #0=don't merge, 1=merge by directory
    HANDLE_PROC_ERRORS => 2, #0=leave empty target, 1=delete empty target, 2=copy source to target
    LOG_INIT => { #log4perl needs these property names to be flat
        'log4perl.logger' => 'TRACE, screen, file',
        'log4perl.appender.screen' => 'Log::Log4perl::Appender::Screen',
        'log4perl.appender.screen.layout' => 'Log::Log4perl::Layout::PatternLayout',
        'log4perl.appender.screen.layout.ConversionPattern' => '%d %p %l - %m%n',
        'log4perl.appender.screen.Threshold' => 'INFO',
            
        'log4perl.appender.file' => 'Log::Log4perl::Appender::File',
        'log4perl.appender.file.filename' => 'optimize_source.log',
        'log4perl.appender.file.mode' => 'append',
        'log4perl.appender.file.layout' => 'Log::Log4perl::Layout::PatternLayout',
        'log4perl.appender.file.layout.ConversionPattern' => '%d %p %l - %m%n',
        'log4perl.appender.file.Threshold' => 'DEBUG',    
    },
};

Log::Log4perl->init($config->{LOG_INIT});
my $logger = Log::Log4perl->get_logger(__FILE__);

$logger->trace("ARGV=" . join("\n", @ARGV));

my $count = 0; #total files
my $mCount = 0; #modified files
my $pCount = 0; #processed files (attempted)
my $psCount = 0; #successfully processed files
my $pfCount = 0; #unsuccessfully processed files
my $mfCount = 0; #merge files
my $mdfCount = 0; #merged files
my $altCount = 0; #alt extension files

my $files = {};
my $dirs = {};
my $alldirs = {};

$SIG{'INT'} = \&interrupt;

$logger->info("Starting...");

my $outdir = ($opt_o) ? $opt_o : $config->{DEFAULT_OUTPUT_DIR};
if($outdir) {
    if($config->{HANDLE_OUTPUT_DIR} == 2) {
        if(-d $outdir) {
            my $odTime = ($^T - ((-M $outdir) * 24 * 60 * 60));
            mvFile($outdir, "${outdir}-${odTime}");
        }
    } elsif($config->{HANDLE_OUTPUT_DIR} == 1) {
        rmDir($outdir);
    } else {
        #$config->{HANDLE_OUTPUT_DIR} == 0
    }
    $outdir = $outdir =~ s|/$||r . '/';    
}

my $rootdirs = [];
if($opt_r) {
    foreach my $rootdir (@$opt_r) {
        push(@$rootdirs, $rootdir =~ s|/$||r . '/');
    }
}
    
system("echo \"\n-------- `date` --------\" >> " . $config->{SYS_ERROR_FILE});
foreach my $item (@$sourceFiles) {
    $logger->trace("Input item '${item}'");
    if((-f $item) && getFileType($item)) {
        $logger->debug("Input file '${item}'.");
        $files->{$item} = 1;
        my $basedir = File::Basename::dirname($item);
        $alldirs->{$basedir} = 1;
    } elsif(-d $item) {
        $logger->debug("Input directory '${item}'.");    
        $dirs->{$item} = 1;
        $alldirs->{$item} = 1;        
    } else {
        $logger->debug("Input unknown or missing '${item}'. Skipping.");        
        #skip
    }
}

foreach my $file (keys(%$files)) {
    fileWorker($file);
}

if(scalar(keys(%$dirs)) > 0) {
    $logger->info("Processing directories, recursively...");
    $logger->info("Searching for modified source files. This may take a while...");
    File::Find::find({
        wanted => \&fileFindWorker,
        postprocess => \&fileFindPostprocessor,
        no_chdir => 1,            
        }, keys(%$dirs));
}

if($config->{MERGE_FILES}) {
    $logger->info("Creating merge files...");
    foreach my $dir (keys(%$alldirs)) {
        mergeFiles($dir);
    }
}


stop();

######## SUBS ########

sub interrupt {
    $logger->info("Process interrupted by ^C from terminal.");
    stop();
}

sub stop {
    done();
}

sub done {
    $logger->info("-------- Summary ------");
    $logger->info("Found a total of ${count} files.");    
    #$logger->info("Found ${mCount} modified or added files since last run.");    
    $logger->info("Attempted to process ${pCount} files.");
    $logger->info("Successfully processed ${psCount} files.");
    $logger->info("Failed to process ${pfCount} files.");
    $logger->info("Copied ${altCount} alternate extension files.");
    if($config->{MERGE_FILES}) {
        $logger->info("Merged ${mdfCount} files into ${mfCount} merge files.");
    }
    $logger->info("The script run time was " . getReadableScriptDuration(time()) . ".");
    $logger->info("-----------------------");
    $logger->info("Done.");
    
    exit(0);
}

sub getOutputFile {
    my ($infile) = @_;
    $logger->trace("infile='${infile}'");
    
    my $outfile = "";
    if($rootdirs) {
        foreach my $rootdir (@$rootdirs) {
            $logger->trace("rootdir=" . $rootdir);
            if($infile =~ /^${\&escape($rootdir)}/) {
                $outfile = $outdir . $infile =~ s|^${\&escape($rootdir)}||r;
                $logger->debug("outfile='${outfile}'");        
                return $outfile;                
            }
        }
    }
    if($infile =~ /^${\&escape($outdir)}/) {
        $outfile = $infile;
        $logger->debug("outfile='${outfile}'");        
        return $outfile;
    }    
    $outfile = $outdir . File::Basename::basename($infile);
    $logger->debug("outfile='${outfile}'");
    return $outfile;
}

sub rmFile {
    my ($file) = @_;
    my $count = 0;
    if(-f $file) {
        $logger->debug("Removing file '${file}'...");            
        $count += unlink($file);
    }
    return $count;
}

sub cpFile {
    my ($file, $newfile) = @_;
    if($file && $newfile) {
        $logger->debug("Copying file '${file}' to '${newfile}'...");
        File::Copy::copy($file, $newfile);
    }
}

sub mvFile {
    my ($file, $newfile) = @_;
    if($file && $newfile) {
        $logger->debug("Copying file '${file}' to '${newfile}'...");
        File::Copy::move($file, $newfile);
    }
}

sub rmDir {
    my ($dir) = @_;
    if(-d $dir) {
        $logger->info("Removing dir path '${dir}'...");
        File::Path::remove_tree($dir);
    }
    return $count;
}

sub mkDir {
    my ($dir) = @_;
    if(!-d $dir) {
        $logger->debug("Creating dir path '${dir}'...");
        File::Path::make_path($dir);
    }
}

sub fileFindWorker {
    fileWorker($File::Find::name);
}

sub fileFindPostprocessor {
    my $dir = $File::Find::dir;
    $logger->trace("Post processing dir '${dir}'...");
    #mergeFiles($dir);
    $alldirs->{$dir} = 1;
    
}

sub mergeFiles {
    my ($dir) = @_;
    if($config->{MERGE_FILES}) {
        $dir = getOutputFile($dir);
        foreach my $type (keys(%{$config->{EXT_MAP}})) {
            my $newExt = $config->{EXT_MAP}->{$type}->{new_ext};
            my @files = glob("${dir}/*${newExt}");            
            if(scalar(@files) <= 0) {
                next;
            }
            my $mergefileName = "merged${type}";
            my $mergefile = "${dir}/${mergefileName}";                    
            my $mergehandle;
            $logger->info("Creating merge file '${mergefile}'...");            
            open($mergehandle, ">" . $mergefile) or do {
                $logger->error("Could not open merge file '${mergefile}' for writing: ${!}");
                next;
            };
            $mfCount++;
            foreach my $file (@files) {
                $logger->debug("Adding contents from file '${file}' to merge file '${mergefileName}'...");
                local $/ = undef; #no line seperator for reading
                my $filehandle;
                open($filehandle, "<" . $file) or $logger->error("Could not open '${file}' for reading into merge file: ${!}");
                my $content = <$filehandle>;
                print($mergehandle $content . "\n");
                close($filehandle) or $logger->error("Could not close '${file}' after reading into merge file: ${!}");                    
                $mdfCount++;
            }
            close($mergehandle) or $logger->error("Could not close merge file '${mergefile}' after writing: ${!}");
        }
    }
}

sub fileWorker {
    my ($filename) = @_;
    $logger->trace("Checking to see if file '${filename}' needs to be processed...");
    if(-d $filename) {
        $logger->trace("File '${filename}' is a directory. skipping...");    
        return;
    }
    if(!-f $filename) {
        $logger->trace("File '${filename}' doesn't exist. skipping...");    
        return;
    }
    
    my $type = getFileType($filename);
    if(!$type) {
        $logger->trace("File '${filename}' is not a type that needs to be processed. skipping...");            
        return;
    }
    my $altFile = isAlternateExtension($filename);
    if($altFile) {
        #rmFile($altFile);
        if(!-f $altFile) {
            $logger->info("Processing file '${filename}' with alternate extension into '" . $config->{EXT_MAP}->{$type}->{'new_ext'} . "'");    
            cpFile($filename, $altFile);
            $count++;
            $altCount++;
        }
        return;
    }    

    $count++;        
    
    $logger->trace("Processing file '${filename}' ...");    
    $logger->trace("found file: ext='${type}', name='${filename}'");
    $logger->debug("Processing file '${filename}' which is a '${type}' file.");
    $mCount++;
    processFile($filename);
}

sub processFile {
    my ($file) = @_;
    my $type = getFileType($file);
    if(!$type) {
        return 0;
    }
    my $processor = $config->{EXT_MAP}->{$type}->{'processor'};
    if(!-f $processor) {
        $logger->fatal("No processor was found for file type '${type}'. Please make sure the file '${processor}' is available.");
        stop();
    }

    $logger->info("Processing file '${file}' into '" . $config->{EXT_MAP}->{$type}->{'new_ext'} . "'");
    $logger->debug("type: ${type}");
    $logger->debug("new ext: " . $config->{EXT_MAP}->{$type}->{'new_ext'});
    my $newfile = getNewFilename($file);
    my $cmd = "trap 'exit 130' 2; ";
    $cmd .= sprintf($config->{EXT_MAP}->{$type}->{'cmd'}, $file, $newfile);
    $logger->debug("cmd: ${cmd}");    
    #redirect output to logfile
    $cmd .= " 1>>" . $config->{SYS_ERROR_FILE} . " 2>&1";
    $logger->trace("cmd: ${cmd}");
    rmFile($newfile);
    
    my $rc = 0;
    mkDir(File::Basename::dirname($newfile));
    $rc = (system($cmd) >> 8);
    if($rc == 130) { interrupt(); }
    
    $pCount++;
    if(!$rc) {
        #system return code 0 is success
        $psCount++;
        $logger->debug("Successfully created file '${newfile}'");
    } else {
        #system return code non 0, error
        $pfCount++;    
        $logger->error("The processor threw an error while processing the file '${file}'. Return code ${rc}. See '" . $config->{SYS_ERROR_FILE} . "' for details.");        
        $logger->debug("Failed to create file '${newfile}'");
        if($config->{HANDLE_PROC_ERRORS} == 1) {
            #remove file
            rmFile($newfile);
        } elsif($config->{HANDLE_PROC_ERRORS} == 2) {
            #copy contents from source file
            rmFile($newfile);
            cpFile($file, $newfile);
        } else {
            #($config->{HANDLE_PROC_ERRORS} == 0)
            #leave as is
        }
    }
    return !$rc;    
}

sub getNewFilename {
    my ($file) = @_;
    my $type = getFileType($file);
    if(!$type) {
        return '';
    }
    my $newfile = $file;
    $newfile =~ s/\.min//i;
    $newfile =~ s/${\&escape($type)}$/$config->{EXT_MAP}->{$type}->{new_ext}/ei;
    $newfile = getOutputFile($newfile);
    return $newfile;
}

sub getFileType {
    my ($filename) = @_;
    if($filename =~ /(\.[^\.]+)$/i) {
        my $type = $1;
        if(exists($config->{EXT_MAP}->{$type})) {
            return $type;
        }
    }
    return '';
}

sub isAlternateExtension {
    my ($file) = @_;
    my $type = getFileType($file);
    my $newExt = $config->{EXT_MAP}->{$type}->{new_ext};    
    my $altExts = $config->{EXT_MAP}->{$type}->{alt_ext};
    foreach my $altExt (@{$altExts}) {
        if($file =~ /${\&escape($altExt)}$/i) {
            $file =~ s/${\&escape($altExt)}$/${newExt}/ei;
            return getOutputFile($file);
        }
    }
    return 0;
}

sub isFileModified {
    my ($file) = @_;
    my $cfile = getNewFilename($file);    
    $logger->trace("file=${file}, cfile=${cfile}");
    if(!-f $file) { return 0; }
    if(!-f $cfile) {
        $cfile = isAlternateExtension($file);
        if(!-f $cfile) {
            return 1;
        }
    }    
    
    #-M is script time minus file modification time in days
    #$^T is script start time in seconds
    #difference in seconds is file mod time
    my $time = ($^T - ((-M $file) * 24 * 60 * 60));
    my $ctime = ($^T - ((-M $cfile) * 24 * 60 * 60));
    my $modified = ($time > $ctime) ? 1 : 0;
    $logger->trace("time=${time}, ctime=${ctime}, modified=${modified}");
    return $modified;
}

sub escape {
    my ($string) = @_;
    $string =~ s|\.|\\.|g;
    return $string
}

sub getReadableScriptDuration {
    my ($end) = @_;
    my $start = $^T;
    my $seconds = ($end - $start);
    my $string = "";
    if(!$seconds) {
        $string .= "less than a second";
    } else {
        my $days = int($seconds / (24 * 60 * 60));
        my $hours = ($seconds / (60 * 60)) %24;
        my $mins = ($seconds / 60) % 60;
        my $secs = $seconds % 60;
        $string .= " ${days} days" if $days;
        $string .= " ${hours} hours" if $hours;
        $string .= " ${mins} minutes" if $mins;
        $string .= " ${secs} seconds" if $secs;
        $string =~ s/^\s//;
    }
    return $string;
}


1;
