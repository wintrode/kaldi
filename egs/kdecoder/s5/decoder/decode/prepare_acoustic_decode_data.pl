#!/usr/bin/env perl
#===============================================================================
# Copyright (c) 2012-2015  Johns Hopkins University (Author: Sanjeev Khudanpur )
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
# WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
# MERCHANTABLITY OR NON-INFRINGEMENT.
# See the Apache 2 License for the specific language governing permissions and
# limitations under the License.
#===============================================================================

use Getopt::Long;
use File::Basename;

########################################################################
#
# Script to prepare the Babel acoustic training data for Kaldi.
#
#  -  Place transcripts in a file named "text"
#     Each line contains: utteranceID word1 word2 ...
#
#  -  Place the utterance-to-speaker map in a file named "utt2spk"
#     Each line contains: utteranceID speakerID
#     speakerID MUST BE be a prefix of the utteranceID
#     Kaldi code does not require it, but some training scripts do.
#
#   -  Place the utterance-to-segment map in a file named "segments"
#      Each line contains: utteranceID recordingID startTime endTime
#
#   -  Place the recordingID-to-waveformFile map in "wav.scp"
#      Each line contains: recordingIB Input_pipe_for_reading_waveform|
#
#  -  Place the speaker-utterance map in a file named "spk2utt"
#     Each line contains: speakerID utteranceID_1 utteranceID_2 ...
#     This is the inverse of the utt2spk mapping
#
# Note 1: the utteranceIDs in the first 3 files must match exactly, and
#         the recordingIDSs in the last 2 files must match exactly.
#
# Note 2: Babel data formats and file-naming conventions are assumed.
#
#   -  The transcriptions and waveforms are in subdirectories named
#        audio/<filename>.sph
#        transcription/<filename>.txt
#      There is 1 pair of files per recording, with extensions as above
#
#   -  The audio is in NIST sphere format, so shp2pipe may be used, e.g.
#        BABEL_BP_101_11694_20111204_205320_inLine \
#        /export/babel/sanjeev/kaldi-trunk/tools/sph2pipe_v2.5/sph2pipe \
#        -f wav -p -c 1 \
#        BABEL_BP_101_11694_20111204_205320_inLine.sph|
#
#   -  The filename contains speaker information, e.g.
#        BABEL_BP_101_37210_20111102_170037_O1_scripted.sph -> 37210_A
#        BABEL_BP_101_37210_20111102_172955_inLine.sph      -> 37210_A
#        BABEL_BP_101_37210_20111102_172955_outLine.sph     -> 37210_B
#      Specifically, the inLine speaker is the same as scripted
#
#   -  The transcription file has time marks in square brackets, e.g.
#        [0.0]
#        <no-speech> 喂 <no-speech>
#        [7.05]
#        啊 听 听唔听到 啊 <no-speech> 你 而家 仲未 上课 系 嘛 <no-speech>
#        [14.07]
#
#  -  If a vocabulary is provided, map all OOV tokens to an OOV symbol,
#     and write out an OOV list with counts to a file named "oovCounts"
#
#     If one or more word-fragment markers are provided, this script
#     checks if an OOV token can be made in-vocabulary by stripping off
#     the markers one  by one from either end of the token.
#
#     The default settings are
#

      $vocabFile = "";       # No vocab file; nothing is mapped to OOV
      $OOV_symbol = "<unk>"; # Default OOV symbol
      $fragMarkers = "";     # No characters are word-fragment markers
#
#  -  Babel transcriptions contain 4 kinds of untranscribed words
#
#         (())         designates unintelligible words
#         <foreign>    designates a word in another language
#         <prompt>     designates a sequence of pre-recorded words
#         <overlap>    designates two simultaneous foreground speakers
#
#     This script maps them to OOV.  They are not included in oovCounts
#
#  -  Babel transcriptions also contain a few non-linguistics tokens
#
#         <limspack>   map to a vocal noise symbol
#         <breath>     map to a vocal noise symbol
#         <cough>      map to a vocal noise symbol
#         <laugh>      map to a vocal noise symbol
#
#         <click>      map to a nonvocal noise symbol
#         <ring>       map to a nonvocal noise symbol
#         <dtmf>       map to a nonvocal noise symbol
#         <int>        map to a nonvocal noise symbol
#
#         <no-speech>  designates silence > 1 sec.
#
      $vocalNoise = "<v-noise>";
      $nVoclNoise = "<noise>";
      $silence    = "<silence>";
      $icu_transform="";
      $get_whole_transcripts = "false";
#
########################################################################

my $bzipped=0;

my %UNK_NS=();

print STDERR "$0 " . join(" ", @ARGV) . "\n";
GetOptions("fragmentMarkers=s" => \$fragMarkers,
           "oov=s" => \$OOV_symbol, 
           "vocab=s" => \$vocabFile,
	   "bzip"    => \$bzipped,
           "icu-transform=s" => \$icu_transform,
           "get-whole-transcripts=s" => \$get_whole_transcripts
           );

if ($#ARGV == 1) {
    $workfile = $ARGV[0];
    $outDir   = $ARGV[1];
    print STDERR ("$0: $workfile $outDir\n");
    print STDERR ("$0 ADVICE: Use full path for the Input Directory\n") unless ($inDir=~m:^/:);
} else {
    print STDERR ("Usage: $0 [--options] InputDir OutputDir\n");
    print STDERR ("\t--fragmentMarkers <chars>  Remove these from ends of words to minimize OOVs (default none)\n");
    print STDERR ("\t--get-whole-transcripts (true|false) Do not remove utterances containing no speech\n");
    exit(1);
}

unless ( -d $outDir ) {
    print STDERR ("$0: Creating output directory $outDir\n");
    die "Failed to create output directory" if (`mkdir -p $outDir`);
}


if ($bzipped) {
    mkdir ($outDir/audioTmp);
    open WF, "< $workfile";
    open WFB, "> $outDir/workfile";
    while (<WF>) {
	chomp;
	($audio, $marks, $output) = split;
	if ($audio =~ /.bz2$/) {
	    $name = basename($audio);
	    $name =~ s/.bz2$//;
	    system("bunzip2 -c $audio > $outdir/audioTmp/$name");
	    print WFB "$outDir/audioTmp/$name $marks $output\n";
	}
	else {
	    print WFB "$audio $marks $name\n";
	}
    }
    close WF;
    close WFB;
    $workfile = "$outDir/workfile";
}



########################################################################
# First read segmentation information from all the transcription files
########################################################################


if (-f $workfile) {
    @TranscriptionFiles = ();  # probably don't have any
    @AudioFiles = ();
    open WRF, "< $workfile";
    $numFiles = $numUtterances = $numWords = $numOOV = $numSilence = 0;
    while (<WRF>) {
	chomp;
	($audiofile, $markfile, $outputDir) = split;
	push @AudioFiles, $audiofile;

	$fileID =  basename($audiofile);  # To capture the base file name
	$fileID =~ s/.[a-z0-9]*$//; # remove file extension (will fail on compressed files)

	# For each audio file, extract and save segmentation data
	$numUtterancesThisFile = 0;
	$prevTimeMark = -1.0;
	$text = "";

	open TRANSCRIPT, "< $markfile" || die "Unable to open $markfile for $fileID";
	while (<TRANSCRIPT>) {
	    chomp;
	    ($start, $end) = split;
	    $dur = $end - $start;
	    $thisTimeMark=$start;
	    if ($dur < 0) {
		print STDERR ("$0 ERROR: Found segment with negative duration in $filename\n");
		print STDERR ("\tStart time = $prevTimeMark, End time = $thisTimeMark\n");
		print STDERR ("\tThis could be a sign of something seriously wrong!\n");
		print STDERR ("\tFix the file by hand or remove it from the directory, and retry.\n");
		exit(1);
	    }
	    
	    if (100*$start >= 100000) {
		die "File is too long ($start ms)";
	    }

	    $utteranceID = $fileID;
	    $utteranceID .= sprintf("_%06i", (100*$start));

	    ##################################################
	    # Then save segmentation, transcription, spkeaerID
	    ##################################################
	    if (exists $start{$utteranceID}) {
		# utteranceIDs should be unique, but this one is not!
		# Either time marks in the transcription file are bad,
		# or something went wrong in generating the utteranceID
		print STDERR ("$0 WARNING: Skipping duplicate utterance $utteranceID\n");
		next;
	    }
	    else {
		$startTime{$utteranceID} = $start;
		$endTime{$utteranceID} = $end;
		
		$transcription{$utteranceID} = "<unk>";
		$startTime{$utteranceID} = $prevTimeMark;
		$endTime{$utteranceID} = $thisTimeMark;
		
		$speakerID{$utteranceID} = $fileID;
		$baseFileID{$utteranceID} = $fileID;

		$numUtterancesThisFile++;
		$numUtterances++;
	    }
	}

	close(TRANSCRIPT);
	if ($numUtterancesThisFile>0) {
	    $lastTimeMarkInFile{$fileID} = $end;
	    $numUtterancesInFile{$fileID} = $numUtterancesThisFile;
	    $numUtterancesThisFile = 0;
	}
	$numFiles++;
    }
    close WF;
    print STDERR ("$0: Recorded $numUtterances non-empty utterances from $numFiles files\n");

}
else {
    print STDERR ("$0 ERROR: No workfile named $workfile\n");
    exit(1);
}

########################################################################
# Then verify existence of corresponding audio files and their durations
########################################################################

if ($#AudioFiles >= 0) {
    printf STDERR ("$0: Found %d audio files in $workfile\n", ($#AudioFiles +1));
    $numFiles = 0;
    foreach $filename (@AudioFiles) {
	$fileID = $filename;
	$fileID = basename($filename);

	if ($fileID =~ s/\.sph$//)  {  # remove file extension

	    if (exists $numUtterancesInFile{$fileID}) {
	    # Some portion of this file has training transcriptions
		@Info = `head $filename`;
		$SampleCount = -1;
                $SampleRate  = 8000; #default
                while ($#Info>=0) {
		    $line = shift @Info;
		    $SampleCount = $1 if ($line =~ m:sample_count -i (\d+):); 
		    $SampleRate  = $1 if ($line =~ m:sample_rate -i (\d+):); 
                }
                if ($SampleCount<0) {
                    # Unable to extract a valid duration from the sphere header
                    print STDERR ("Unable to extract duration: skipping file $filename");
                } else {
                    $waveformName{$fileID} = $filename; chomp $waveformName{$fileID};
                    $duration{$fileID} = $SampleCount/$SampleRate;
                    $numFiles++;
                }
            } else {
                # Could be due to text filtering resulting in an empty transcription
                # Output information to STDOUT to enable > /dev/null
		$duration{$fileID}=0;
                print STDOUT ("$0: No transcriptions for audio file ${fileID}.sph\n");
            }
	}
	elsif ($fileID =~ s/.wav$//) { 
	    $soxi=`which soxi` or die "$0: Could not find soxi binary -- do you have sox installed?\n";
	    chomp $soxi;
            if (exists $numUtterancesInFile{$fileID}) {
                # Some portion of this file has training transcriptions
                $samples = `$soxi -s $filename`; chomp $samples;
                $rate = `$soxi -r $filename`; chomp $rate;
                $duration= 1.0 * $samples / $rate;
                if ($duration <=0) {
                    # Unable to extract a valid duration from the sphere header
                    print STDERR ("Unable to extract duration: skipping file $filename");
                } else {
                    if (exists $waveformName{$fileID} ) {
                      print STDERR ("$0 ERROR: duplicate fileID \"$fileID\" for files \"$filename\" and \"" . $waveformName{$fileID} ."\"\n");
                      exit(1);
                    }
                    $waveformName{$fileID} = $filename; chomp $waveformName{$fileID};
                    $duration{$fileID} = $duration;
                    $numFiles++;
                }
            } else {
                # Could be due to text filtering resulting in an empty transcription
                # Output information to STDOUT to enable > /dev/null
                print STDOUT ("$0: No transcriptions for audio file ${fileID}.sph\n");
            }
        }
	
	if ( $#waveformName == 0 ) {
	    print STDERR ("$0 ERROR: No audio files found!");
	}
    } 
} 
else {
    print STDERR ("$0 ERROR: No audio in  $workfile\n");
    exit(1);
}

########################################################################
# Now all the needed information is available.  Write out the 4 files.
########################################################################

unless (-d $outDir) {
    print STDERR ("$0: Creating output directory $outDir\n");
    die "Failed to create output directory" if (`mkdir -p $outDir`); # i.e. if the exit status is not zero.
}
print STDERR ("$0: Writing 5 output files to $outDir\n");

$textFileName = "$outDir/text";
open (TEXT, "> $textFileName") || die "$0 ERROR: Unable to write text file $textFileName\n";

$utt2spkFileName = "$outDir/utt2spk";
open (UTT2SPK, "> $utt2spkFileName") || die "$0 ERROR: Unable to write utt2spk file $utt2spkFileName\n";

$segmentsFileName = "$outDir/segments";
open (SEGMENTS, "> $segmentsFileName") || die "$0 ERROR: Unable to write segments file $segmentsFileName\n";

$scpFileName = "$outDir/wav.scp";
open (SCP, "| sort -u >  $scpFileName") || die "$0 ERROR: Unable to write wav.scp file $scpFileName\n";
my $binary=`which sph2pipe` or die "Could not find the sph2pipe command"; chomp $binary;
$SPH2PIPE ="$binary -f wav -p -c 1";
my $SOXBINARY =`which sox` or die "Could not find the sph2pipe command"; chomp $SOXBINARY;
$SOXFLAGS ="-r 8000 -c 1 -b 16 -t wav - ";

$spk2uttFileName = "$outDir/spk2utt";
open (SPK2UTT, "> $spk2uttFileName") || die "$0 ERROR: Unable to write spk2utt file $spk2uttFileName\n";

$oovFileName = "$outDir/oovCounts";
open (OOV, "| sort -nrk2 > $oovFileName") || die "$0 ERROR: Unable to write oov file $oovFileName\n";

open (RECO, "| sort > $outDir/reco2file_and_channel");# || die "$0 ERROR: Unable to write reco2file_and_channel\n";

$numUtterances = $numSpeakers = $numWaveforms = 0;
$totalSpeech = $totalSpeechSq = 0.0;
foreach $utteranceID (sort keys %transcription) {
    $fileID = $baseFileID{$utteranceID};
    if (exists $waveformName{$fileID}) {
        # There are matching transcriptions and audio
	print "$utteranceID $transcription{$utteranceID} $startTime{$utteranceID}\n";

        $numUtterances++;
      	$totalSpeech += ($endTime{$utteranceID} - $startTime{$utteranceID});
        $totalSpeechSq += (($endTime{$utteranceID} - $startTime{$utteranceID})
			   *($endTime{$utteranceID} - $startTime{$utteranceID}));
        print TEXT ("$utteranceID $transcription{$utteranceID}\n");
        print UTT2SPK ("$utteranceID $speakerID{$utteranceID}\n");
        print SEGMENTS ("$utteranceID $fileID $startTime{$utteranceID} $endTime{$utteranceID}\n");
        if (exists $uttList{$speakerID{$utteranceID}}) {
            $uttList{$speakerID{$utteranceID}} .= " $utteranceID";
        } else {
            $numSpeakers++;
            $uttList{$speakerID{$utteranceID}} = "$utteranceID";
        }
        next if (exists $scpEntry{$fileID});
        $numWaveforms++;
        if ($waveformName{$fileID} =~ /.*\.sph/ ) {
          $scpEntry{$fileID} = "$SPH2PIPE $waveformName{$fileID} |";
        } else {
          $scpEntry{$fileID} = "$SOXBINARY $waveformName{$fileID} $SOXFLAGS |";
        }
    } else {
        print STDERR ("$0 WARNING: No audio file for transcription $utteranceID\n");
    }
}
foreach $fileID (sort keys %scpEntry) {
    print SCP ("$fileID $scpEntry{$fileID}\n");
}
foreach $speakerID (sort keys %uttList) {
    print SPK2UTT ("$speakerID $uttList{$speakerID}\n");
}
foreach $w (sort keys %oovCount) {
    print OOV ("$w\t$oovCount{$w}\n");
}
exit(1) unless (close(TEXT) && close(UTT2SPK) && close(SEGMENTS) && close(SCP) && close(SPK2UTT) && close(OOV));

print STDERR ("$0: Summary\n");
print STDERR ("\tWrote $numUtterances lines each to text, utt2spk and segments\n");
print STDERR ("\tWrote $numWaveforms lines to wav.scp\n");
print STDERR ("\tWrote $numSpeakers lines to spk2utt\n");
print STDERR ("\tHmmm ... $numSpeakers distinct speakers in this corpus? Unusual!\n")
    if (($numSpeakers<($numUtterances/500.0)) || ($numSpeakers>($numUtterances/2.0)));
print STDERR ("\tTotal # words = $numWords (including $numOOV OOVs) + $numSilence $silence\n")
    if ($vocabFile);
printf STDERR ("\tAmount of speech = %.2f hours (including some due to $silence)\n", $totalSpeech/3600.0);
if ($numUtterances>0) {
    printf STDERR ("\tAverage utterance length = %.2f sec +/- %.2f sec, and %.2f words\n",
		   $totalSpeech /= $numUtterances,
		   sqrt(($totalSpeechSq/$numUtterances)-($totalSpeech*$totalSpeech)),
		   $numWords/$numUtterances);
}

exit(0);

########################################################################
# Done!
########################################################################
