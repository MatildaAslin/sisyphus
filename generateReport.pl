#!/usr/bin/perl -w

use FindBin;                # Find the script location
use lib "$FindBin::Bin/lib";# Add the script libdir to libs
use Molmed::Sisyphus::Libpath;

use strict;
use Getopt::Long;
use Pod::Usage;
use Cwd qw(abs_path cwd);
use File::Basename;
use File::Find;
use File::Copy qw/cp move/;
use XML::Simple;
use XML::LibXSLT;
use XML::LibXML;

use Molmed::Sisyphus::Common qw(mkpath);
use Molmed::Sisyphus::QStat;
use Molmed::Sisyphus::Plot;

=pod

=head1 NAME

generateReport.pl - Create a top level report on the runfolder

=head1 SYNOPSIS

 generateReport.pl -help|-man
 generateReport.pl -runfolder <runfolder> [-debug]

=head1 OPTIONS

=over 4

=item -h|-help

prints out a brief help text.

=item -m|-man

Opens the manpage.

=item -runfolder

The runfolder to generate report on.

=item -debug

Print debugging information

=back

=head1 DESCRIPTION

Collects statistics and other data into the folder Summary, which
can then be copied to the GA-summaries folder for future reference.
Creates a top-level report with various metrics about the run.
extractProject.pl has to be run first so that the project reports
can be included in the Summary folder and linked from the global report.

=cut

# Parse options
my($help,$man) = (0,0);
my($rfPath) = (undef);
our($debug) = 0;

GetOptions('help|?'=>\$help,
	   'man'=>\$man,
	   'runfolder=s' => \$rfPath,
	   'debug' => \$debug,
	  ) or pod2usage(-verbose => 0);
pod2usage(-verbose => 1)  if ($help);
pod2usage(-verbose => 2)  if ($man);

unless(defined $rfPath && -e $rfPath){
    print STDERR "Runfolder not specified or does not exist\n";
    pod2usage(-verbose => 1);
    exit;
}

# Create a new sisyphus object for common functions
my $sisyphus = Molmed::Sisyphus::Common->new(PATH=>$rfPath, DEBUG=>$debug);
$sisyphus->runParameters();
$rfPath = $sisyphus->PATH;
my $machineType = $sisyphus->machineType();

# Set the output path
my $outDir = "$rfPath/Summary";

# Create the output directory
if(-e "$outDir"){
    my $t = time();
    move("$outDir", "$outDir.old.$t") or die "Failed to rename old Summary folder: $!\n";
}
mkpath("$outDir", 2770) or die "Failed to create dir '$rfPath/Summary': $!\n";

$outDir = abs_path($outDir);
print STDERR "Summary directory: $outDir\n" if($debug);

my $plotter = Molmed::Sisyphus::Plot->new();

# Read the sample sheet
my $sampleSheet = $sisyphus->readSampleSheet();
$sisyphus->runParameters();
my @projects = sort keys %{$sampleSheet};
push @projects, 'Undetermined_indices' if(-e "$rfPath/Statistics/Project_Undetermined_indices");

# Get the statistics generated by RTA/CASAVA
my($RtaLaneStats,$RtaSampleStats) = $sisyphus->resultStats();

# assume the same offset for all files (set in the loop below)
my $offset = 0;

# Read all stats from the project dirs
my %dumps;
foreach my $project (@projects){
    my $projDir = "$rfPath/Statistics/Project_$project";
    unless(-e "$projDir/extractProject.complete" || -e "$projDir/extractProject.complete.gz"){
	unless($project eq 'Undetermined_indices'){
	    die "$project has not been extracted yet. Aborting\n";
	}
    }
    if(-e $projDir){
	opendir(my $pDirFh, $projDir) or die "Failed to open '$projDir': $!\n";
	foreach my $sampleDir (grep /^[^\.]/, readdir($pDirFh)){
	    next unless (-d "$projDir/$sampleDir");
	    opendir(my $sDirFh, "$projDir/$sampleDir") or die "Failed to open '$projDir/$sampleDir': $!\n";
	    foreach my $statfile (grep /\.statdump.zip$/, readdir($sDirFh)){
		my $stat = Molmed::Sisyphus::QStat->new(DEBUG=>$debug);
		$stat->loadData("$projDir/$sampleDir/$statfile");
		my $lane = $stat->{LANE};
		$offset = $stat->{OFFSET} unless($offset);
		push @{$dumps{$project}->{$lane}}, $stat;
	    }
	    closedir($sDirFh);
	}
	closedir($pDirFh);
    }
}

open(my $reportFh, '>', "$outDir/summaryReport.xml");
print $reportFh q(<?xml version="1.0"?>), "\n";
print $reportFh q(<?xml-stylesheet type="text/xsl" href="summaryReport.xsl"?>), "\n";
print $reportFh q(<SummaryReport xmlns="illuminareport.xml.molmed">), "\n";
my $xs = XML::Simple->new(RootName=>undef);
if($sisyphus->machineType() eq 'miseq'){
    cp("$FindBin::Bin/summaryReportMiSeq.xsl", "$outDir/summaryReport.xsl")
      or die "Failed to copy '$FindBin::Bin/summaryReportMiSeq.xsl' to '$outDir/summaryReport.xsl': $!\n";
}else{
    cp("$FindBin::Bin/summaryReport.xsl", "$outDir/summaryReport.xsl")
      or die "Failed to copy '$FindBin::Bin/summaryReport.xsl' to '$outDir/summaryReport.xsl': $!\n";
}

# Compile per lane statistics
my %laneStat;
my $laneXmlData = {};
my $numLanes = $sisyphus->laneCount();

foreach my $lane (1..$numLanes){
    print STDERR "Compiling data for lane $lane\n";
    $laneStat{$lane} = undef;
    $laneXmlData->{Lane}->{$lane}={};

    sumLane(\%dumps, \%laneStat, $lane, \@projects);

    if(! defined $laneStat{$lane}){
	# A skipped lane without data
	my $rId = 0;
	foreach my $read ($sisyphus->reads()){
	    next if($read->{index} eq 'Y');
	    $rId++;
	    my %metrics;
	    $metrics{Id} = $rId;
	    # Add the RTA/CASAVA metrics
	    foreach my $key (keys %{$RtaLaneStats->{$lane}->{$rId}}){
		$metrics{$key} = $RtaLaneStats->{$lane}->{$rId}->{$key};
	    }
	    push @{$laneXmlData->{Lane}->{$lane}->{Read}}, \%metrics;
	}
	next;
    }

    my $read = 0;
    foreach my $readInfo ($sisyphus->reads()){
	next if($readInfo->{index} eq 'Y');
	$read++;
	my %metrics = ();
	if(exists $laneStat{$lane} && exists $laneStat{$lane}->{$read}){
	    %metrics = $laneStat{$lane}->{$read}->metrics();
#	    $laneStat{$lane}->{$read}->{METRICS}=\%metrics;
	    $metrics{Id} = $metrics{Read};
	    delete($metrics{Read});
	    delete($metrics{Lane});
	}

	# Add the RTA/CASAVA metrics
	foreach my $key (keys %{$RtaLaneStats->{$lane}->{$read}}){
	    if($key eq 'Excluded'){
		foreach my $eKey (keys %{$RtaLaneStats->{$lane}->{$read}->{Excluded}}){
		    $metrics{Excluded}->{$eKey} = $RtaLaneStats->{$lane}->{$read}->{Excluded}->{$eKey};
		}
	    }else{
		$metrics{$key} = $RtaLaneStats->{$lane}->{$read}->{$key};
	    }
	}

	if(exists $laneStat{$lane} && exists $laneStat{$lane}->{$read}){
	    my $stat = $laneStat{$lane}->{$read};
	    my $plotTitle = $sisyphus->RUNFOLDER . ', Lane ' . $stat->LANE . ', Read ' . $stat->READ;

	    my @qplot = $plotter->plotQval($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-Qscores", "Q-score distribution $plotTitle");
	    ($metrics{QscorePlot} = $qplot[0]) =~ s/^$outDir\///;
	    ($metrics{QscorePlotThumb} = $qplot[1]) =~ s/^$outDir\///;

	    my @aplot = $plotter->plotAdapters($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-Adapters", "Adapter sequences $plotTitle");
	    ($metrics{AdapterPlot} = $aplot[0]) =~ s/^$outDir\///;
	    ($metrics{AdapterPlotThumb} = $aplot[1]) =~ s/^$outDir\///;

	    my @bplot = $plotter->plotBaseComposition($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-BaseComp", "Base Composition $plotTitle");
	    ($metrics{BaseCompPlot} = $bplot[0]) =~ s/^$outDir\///;
	    ($metrics{BaseCompPlotThumb} = $bplot[1]) =~ s/^$outDir\///;

	    my @gcplot = $plotter->plotGCdistribution($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-GCdist", "GC Distribution $plotTitle");
	    ($metrics{GCPlot} = $gcplot[0]) =~ s/^$outDir\///;
	    ($metrics{GCPlotThumb} = $gcplot[1]) =~ s/^$outDir\///;

	    my @lplot = $plotter->plotQ30Length($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-Q30Length", "Q30Length $plotTitle");
	    ($metrics{Q30Plot} = $lplot[0]) =~ s/^$outDir\///;
	    ($metrics{Q30PlotThumb} = $lplot[1]) =~ s/^$outDir\///;

	    my @dplot = $plotter->plotDuplications($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-Duplicate", "Duplications $plotTitle");
	    ($metrics{DupPlot} = $dplot[0]) =~ s/^$outDir\///;
	    ($metrics{DupPlotThumb} = $dplot[1]) =~ s/^$outDir\///;

            my @qpbplot = $plotter->plotQPerBase($stat,"$outDir/Plots/LanePlots/L00$lane-R$read-QvaluePerBase", "Q value per base $plotTitle");
            ($metrics{QValuePerBase} = $qpbplot[0]) =~ s/^$outDir\///;
            ($metrics{QValuePerBaseThumb} = $qpbplot[1]) =~ s/^$outDir\///;

	}
        push @{$laneXmlData->{Lane}->{$lane}->{Read}}, \%metrics;
    }
}

print $reportFh $xs->XMLout($laneXmlData, RootName=>'LaneMetrics', KeyAttr => {Lane => 'Id'});


# Compile per project statistics
my $projXmlData;
foreach my $project (@projects){
    print STDERR "Compiling data for $project\t";
    $projXmlData->{Project}->{$project}={};

    # Sum all data for the project
    my %lStat;
    my %pStat;
    my %pCasava;
    my %lCasava;
    sumProject(\%dumps, \%pStat, \%lStat, \%pCasava, \%lCasava, $project, $RtaSampleStats, $sisyphus);

    my @lanes = keys %lStat;

    foreach my $read (sort {$a<=>$b} keys %{pStat}){
	print STDERR "Read $read\t";

        my $stat = $pStat{$read};
        my %metrics = $stat->metrics();
	die "Could not get any metrics\n" unless(%metrics);
        $metrics{Id} = $metrics{Read};
        delete($metrics{Read});
        delete($metrics{Lane});

	# Add the RTA/CASAVA metrics
	foreach my $key (keys %{$pCasava{$read}}){
	    $metrics{$key} = $pCasava{$read}->{$key};
	}

        my $plotTitle = $sisyphus->RUNFOLDER . ', Project ' . $project . ', Read ' . $stat->READ;

        my @qplot = $plotter->plotQval($stat,"$outDir/Plots/ProjPlots/$project-R$read-Qscores", "Q-score distribution $plotTitle");
        ($metrics{QscorePlot} = $qplot[0]) =~ s/^$outDir\///;
        ($metrics{QscorePlotThumb} = $qplot[1]) =~ s/^$outDir\///;

        my @aplot = $plotter->plotAdapters($stat,"$outDir/Plots/ProjPlots/$project-R$read-Adapters", "Adapter sequences $plotTitle");
        ($metrics{AdapterPlot} = $aplot[0]) =~ s/^$outDir\///;
        ($metrics{AdapterPlotThumb} = $aplot[1]) =~ s/^$outDir\///;

        my @bplot = $plotter->plotBaseComposition($stat,"$outDir/Plots/ProjPlots/$project-R$read-BaseComp", "Base Composition $plotTitle");
        ($metrics{BaseCompPlot} = $bplot[0]) =~ s/^$outDir\///;
        ($metrics{BaseCompPlotThumb} = $bplot[1]) =~ s/^$outDir\///;

        my @gcplot = $plotter->plotGCdistribution($stat,"$outDir/Plots/ProjPlots/$project-R$read-GCdist", "GC Distribution $plotTitle");
        ($metrics{GCPlot} = $gcplot[0]) =~ s/^$outDir\///;
        ($metrics{GCPlotThumb} = $gcplot[1]) =~ s/^$outDir\///;

	my @lplot = $plotter->plotQ30Length($stat,"$outDir/Plots/ProjPlots/$project-R$read-Q30Length", "Q30Length $plotTitle");
	($metrics{Q30Plot} = $lplot[0]) =~ s/^$outDir\///;
	($metrics{Q30PlotThumb} = $lplot[1]) =~ s/^$outDir\///;

        my @dplot = $plotter->plotDuplications($stat,"$outDir/Plots/ProjPlots/$project-R$read-Duplicate", "Duplications $plotTitle");
        ($metrics{DupPlot} = $dplot[0]) =~ s/^$outDir\///;
        ($metrics{DupPlotThumb} = $dplot[1]) =~ s/^$outDir\///;

        my @qpbplot = $plotter->plotQPerBase($stat,"$outDir/Plots/ProjPlots/$project-R$read-QvaluePerBase", "Q value per base $plotTitle");
        ($metrics{QValuePerBase} = $qpbplot[0]) =~ s/^$outDir\///;
        ($metrics{QValuePerBaseThumb} = $qpbplot[1]) =~ s/^$outDir\///;

	foreach my $lane (sort{$a<=>$b} @lanes){
	    next unless(exists $lStat{$lane}); # The undetermined_indices will not have data for lanes where no index was used
	    my $lstat = $lStat{$lane}->{$read};
	    my %lmetrics = $lstat->metrics();
	    die "Could not get any metrics\n" unless(%lmetrics);
	    $lmetrics{Id} = $lane;
	    delete($lmetrics{Read});
	    delete($lmetrics{Lane});

	    # Add the RTA/CASAVA metrics
	    foreach my $key (keys %{$lCasava{$lane}->{$read}}){
		$lmetrics{$key} = $lCasava{$lane}->{$read}->{$key};
	    }

	    my $plotTitle = $sisyphus->RUNFOLDER . ', Project ' . $project . ', LANE ' . $lane .  ', Read ' . $lstat->READ;

	    my @qplot = $plotter->plotQval($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-Qscores", "Q-score distribution $plotTitle");
	    ($lmetrics{QscorePlot} = $qplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{QscorePlotThumb} = $qplot[1]) =~ s/^$outDir\///;

	    my @aplot = $plotter->plotAdapters($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-Adapters", "Adapter sequences $plotTitle");
	    ($lmetrics{AdapterPlot} = $aplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{AdapterPlotThumb} = $aplot[1]) =~ s/^$outDir\///;

	    my @bplot = $plotter->plotBaseComposition($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-BaseComp", "Base Composition $plotTitle");
	    ($lmetrics{BaseCompPlot} = $bplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{BaseCompPlotThumb} = $bplot[1]) =~ s/^$outDir\///;

	    my @gcplot = $plotter->plotGCdistribution($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-GCdist", "GC Distribution $plotTitle");
	    ($lmetrics{GCPlot} = $gcplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{GCPlotThumb} = $gcplot[1]) =~ s/^$outDir\///;

	    my @lplot = $plotter->plotQ30Length($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-Q30Length", "Q30Length $plotTitle");
	    ($lmetrics{Q30Plot} = $lplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{Q30PlotThumb} = $lplot[1]) =~ s/^$outDir\///;

	    my @dplot = $plotter->plotDuplications($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-Duplicate", "Duplications $plotTitle");
	    ($lmetrics{DupPlot} = $dplot[0]) =~ s/^$outDir\///;
	    ($lmetrics{DupPlotThumb} = $dplot[1]) =~ s/^$outDir\///;

            my @qpbplot = $plotter->plotQPerBase($lstat,"$outDir/Plots/ProjPlots/Lane$lane/$project-R$read-QvaluePerBase", "Q value per base $plotTitle");
            ($lmetrics{QValuePerBase} = $qpbplot[0]) =~ s/^$outDir\///;
            ($lmetrics{QValuePerBaseThumb} = $qpbplot[1]) =~ s/^$outDir\///;

	    push @{$metrics{Lane}}, \%lmetrics;
	}

        push @{$projXmlData->{Project}->{$project}->{Read}}, \%metrics;
    }
    print STDERR "\n";
}

print $reportFh $xs->XMLout($projXmlData, RootName=>'ProjectMetrics', KeyAttr => {Project => 'Id', Lane => 'Id'});

# Collect run information
my %metaData;
$metaData{RunFolder} = $sisyphus->runfolder();
$metaData{SisyphusVersion} = $sisyphus->version();
$metaData{CsVersion} = $sisyphus->getCSversion();
$metaData{InstrumentModel} = $sisyphus->machineType();
$metaData{RtaVersion} = $sisyphus->getRTAversion();
$metaData{FlowCellId} = $sisyphus->fcId();
$metaData{ClusterKitVersion} = $sisyphus->getClusterKitVersion();
$metaData{Qoffset} = $offset;
$metaData{bcl2fastqVersion} = $sisyphus->getBcl2FastqVersion();
# metaData information only available for HiSeq
if($sisyphus->machineType() ne 'miseq'){
   $metaData{FlowCellVer} = $sisyphus->getFlowCellVersion();
   $metaData{SBSversion} = $sisyphus->getSBSversion();
}

my $runInfo = $sisyphus->getRunInfo();
for(my $i=0; $i<@{$runInfo->{reads}}; $i++){
    my $read = $runInfo->{reads}->[$i];
    my $cycles = $read->{last} - $read->{first}; # The last cycle is discarded, so do not add one here
    if($runInfo->{indexed}){
	if($read->{id} != 2){
	    my $id = $read->{id};
	    if($runInfo->{indexed} && $id>1){ # Do not count the index read
		$id -= 1;
	    }
	    push @{$metaData{Read}}, {Id=>$id, Cycles=>$cycles};
	}
    }else{
	push @{$metaData{Read}}, {Id=>$read->{id}, Cycles=>$cycles};
    }
}
print $reportFh $xs->XMLout(\%metaData, RootName=>'MetaData');


print $reportFh q(</SummaryReport>), "\n";

close($reportFh);

# Transform xml + xsl to html
my $xslt = XML::LibXSLT->new();
my $stylesheet = $xslt->parse_stylesheet(XML::LibXML->load_xml(location=>"$outDir/summaryReport.xsl", no_cdata=>1));
my $xmlData = stripXmlNameSpace("$outDir/summaryReport.xml");

open(my $htmlFh, '>', "$outDir/summaryReport.html") or die "Failed to open '$outDir/summaryReport.xsl' for writing: $!\n";
print $htmlFh
    $stylesheet->output_as_bytes(
	$stylesheet->transform(
	    XML::LibXML->load_xml(
		string => $xmlData
	    )
	)
    );
close($htmlFh);

# Link project reports
foreach my $project (@projects){
    linkDir("$rfPath/Statistics/Project_$project", "$outDir/$project");
}

# Calculate checksums for all summary files
$sisyphus->md5Dir($outDir, -noCache=>1, -save=>1);

sub linkDir{
    my $srcDir = shift;
    my $targetDir = shift;
    unless(-e $targetDir){
	mkpath($targetDir, 2770) or die "Failed to create path '$targetDir': $!\n";
    }
    opendir(my $sdFh, $srcDir) or die "Failed to open dir '$srcDir': $!\n";
    while(my $file = readdir($sdFh)){
	next if($file=~m/^\.+$/);
	next if($file=~m/\.fastq(\.gz)?$/);
	next if($file eq 'extractProject.complete');
	if(-d "$srcDir/$file"){
	    linkDir("$srcDir/$file", "$targetDir/$file");
	}else{
	    link("$srcDir/$file", "$targetDir/$file") || die qq(Failed to link "$srcDir/$file", "$targetDir/$file": $!\n);
	}
    }
    closedir($sdFh);
}

sub sumLane{
    my $dumps = shift;
    my $laneStat = shift;
    my $lane = shift;
    my $projects = shift;

    my %samples;
    foreach my $proj (@{$projects}){
	if(exists $dumps->{$proj}->{$lane} && ref $dumps->{$proj}->{$lane} eq 'ARRAY'){
	    foreach my $stat (@{$dumps->{$proj}->{$lane}}){
		my $read = $stat->{READ};
		if(defined $laneStat->{$lane}->{$read}){
		    my $tmp = $laneStat->{$lane}->{$read}->add($stat);
		    $laneStat->{$lane}->{$read} = $tmp;
		}else{
		    $laneStat->{$lane}->{$read} = $stat->copy;
		}
		$samples{$read}++ unless($proj =~ /undetermined_indices/i);
	    }
	}
    }
    foreach my $r (keys %samples){
	if(exists $laneStat->{$lane}->{$r}){
	    $laneStat->{$lane}->{$r}->{SamplesOnLane} = $samples{$r};
	}
    }
}

sub sumProject{
    my $dumps = shift;
    my $pStat = shift;
    my $lStat = shift;
    my $pCasava = shift;
    my $lCasava = shift;
    my $proj = shift;
    my $rtaStat = shift;

    foreach my $l (keys %{$dumps->{$proj}}){
	my $laneData = $dumps->{$proj}->{$l};
	foreach my $stat (@{$laneData}){
	    my $read = $stat->READ;
	    if(defined $pStat->{$read}){
		my $tmp = $pStat->{$read}->add($stat);
		$pStat->{$read} = $tmp;
	    }else{
		$pStat->{$read} = $stat->copy;
	    }
	    if(defined $lStat->{$l}->{$read}){
		my $tmp = $lStat->{$l}->{$read}->add($stat);
		$lStat->{$l}->{$read} = $tmp;
	    }else{
		$lStat->{$l}->{$read} = $stat->copy;
	    }

	    unless(exists $pCasava->{$read}){
		$pCasava->{$read} = {
				     QscoreSum  => 0,
				     PctLane    => 0,
				     YieldPF    => 0,
				     PF         => 0,
				     mismatchCnt1 => 0,
				     AvgQ       => 0,
				     YieldQ30   => 0,
				     PctQ30     => 0,
				     TagErr     => 0
				    };
	    }
	    unless(exists $lCasava->{$l}->{$read}){
		$lCasava->{$l}->{$read} = {
					   QscoreSum  => 0,
					   PctLane    => 0,
					   YieldPF    => 0,
					   PF         => 0,
					   mismatchCnt1 => 0,
					   AvgQ       => 0,
					   YieldQ30   => 0,
					   PctQ30     => 0,
					   TagErr     => 0
					  };
	    }

	    my $casava = $pCasava->{$read};
	    my $lcasava = $lCasava->{$l}->{$read};
	    my $sample = $stat->SAMPLE;
	    unless($l == $stat->LANE){die "Incongruent lanes!"};
	    my $tag = $stat->TAG;
	    if( ((! defined $tag) || $tag eq '') &&
		(! defined $rtaStat->{$sample}->{$l}->{$read}->{$tag}) &&
		defined $rtaStat->{$sample}->{$l}->{$read}->{'NoIndex'}){
		$tag = 'NoIndex';
	    }

            $tag = $sisyphus->getIndexUsingSampleNumber($l, $proj, $sample, substr($tag,1), $sampleSheet) if($proj ne 'Undetermined_indices');

	    my $data;
	    if($proj eq 'Undetermined_indices'){
	    	$data = $rtaStat->{Undetermined}->{$l}->{$read}->{unknown};
	    }else{
		$data = $rtaStat->{$sample}->{$l}->{$read}->{$tag};
	    }
	    if(defined $data){
		# The averages must be updated before the counts are added
		if($casava->{YieldPF} + $data->{YieldPF} > 0){
		    $casava->{AvgQ} = ($casava->{AvgQ}*$casava->{YieldPF} + $data->{AvgQ} * $data->{YieldPF}) / ($casava->{YieldPF} + $data->{YieldPF});
		    $casava->{PctQ30} = ($casava->{PctQ30}*$casava->{YieldPF} + $data->{YieldPF} * $data->{PctQ30}) / ($casava->{YieldPF} + $data->{YieldPF});
		    $casava->{TagErr} = ($casava->{TagErr}*$casava->{YieldPF} + $data->{TagErr} * $data->{YieldPF}) / ($casava->{YieldPF} + $data->{YieldPF});
		}else{
		    $casava->{AvgQ} = 0;
		    $casava->{PctQ30} = 0;
		    $casava->{TagErr} = 0;
		}

		foreach my $key ( qw(QscoreSum PF YieldPF mismatchCnt1 YieldQ30 PctLane) ){
		    $casava->{$key} += $data->{$key};
		}

		if($lcasava->{YieldPF} + $data->{YieldPF} > 0){
		    $lcasava->{AvgQ} = ($lcasava->{AvgQ}*$lcasava->{YieldPF} + $data->{AvgQ} * $data->{YieldPF}) / ($lcasava->{YieldPF} + $data->{YieldPF});
		    $lcasava->{PctQ30} = ($lcasava->{PctQ30}*$lcasava->{YieldPF} + $data->{YieldPF} * $data->{PctQ30}) / ($lcasava->{YieldPF} + $data->{YieldPF});
		    $lcasava->{TagErr} = ($lcasava->{TagErr}*$lcasava->{YieldPF} + $data->{TagErr} * $data->{YieldPF}) / ($lcasava->{YieldPF} + $data->{YieldPF});
		}else{
		    $lcasava->{AvgQ} = 0;
		    $lcasava->{PctQ30} = 0;
		    $lcasava->{TagErr} = 0;
		}
		foreach my $key ( qw(QscoreSum PF YieldPF mismatchCnt1 YieldQ30 PctLane) ){
		    $lcasava->{$key} += $data->{$key};
		}
	    }else{
		warn "No casava data found for:\n  SAMPLE: $sample\n  LANE: $l\n  TAG: $tag\n";
	    }
	}
    }
}

sub stripXmlNameSpace{
    my $file = shift;
    # Strip the namespace from the xml data, adding it to the xsl is a mess
    $/='';
    open(my $xmlFh, $file) or die;
    my $xmlData = <$xmlFh>;
    close($xmlFh);
    $/="\n";
    $xmlData=~ s/xmlns="illuminareport.xml.molmed"//;
    return $xmlData;
}
