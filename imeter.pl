#!/usr/bin/perl
# Copyright (C) 2007-2014 Ian Korf, Genís Parra, and Keith Brandam
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

use strict; use warnings;
use FAlite;
use Getopt::Std;
use vars qw($opt_w $opt_s $opt_r $opt_g $opt_d $opt_a $opt_c $opt_f $opt_o $opt_m);

################################
#
#   S e t u p
#
################################

# set up some default values
my $window_step = 1;
my $window_size = 7;
my $donor = 5;
my $acceptor = 10;
my $cutoff      =  1.2;
my $gap         = 5; # how far can two peaks be apart to still be considered one peak?
my $gff         = 0; 
my $weighting_factor = 200;

getopts('w:s:d:c:a:f:g:rom:');
$window_size      = $opt_w if $opt_w;
$window_step      = $opt_s if $opt_s;
$donor            = $opt_d if $opt_d;
$acceptor         = $opt_a if $opt_a;
$cutoff           = $opt_c if $opt_c;
$gap              = $opt_g if $opt_g;
$weighting_factor = $opt_f if $opt_f;

$gff = 1 if $opt_o;

die "
Note: Calculates IMEter v2.0 scores, using data trained from Phytozome v9.0 introns

usage: imeter.pl [options] <fasta file>

options:
  -w <int>     window size nt    [default $window_size]
  -s <int>     step size  nt     [default $window_step]
  -d <int>     donor sequence to clip [default $donor]
  -a <int>     acceptor sequence to clip [default $acceptor]
  -g <int>     minimum gap allowed between high scoring windows [default $gap]
  -c <float>   threshold value to decide what is a high scoring window [default $cutoff]
  -f <int>     weighting factor to penalize peaks that are further away [default $weighting_factor]
  -m <file>    IMEter parameter file [default is to use embedded pentamers]
  -r           calculate score for reverse strand
  -o		   print GFF info of each peak

" unless @ARGV == 1;

die "Window size (-w) must be at least 5\n" if ($window_size < 5);
die "Window step (-s) must be <= window size (-w)\n" if ($window_step > $window_size);

my ($FASTA) = @ARGV;


######################################
#
#   R e a d   P a r a m e t e r s
#
######################################

my ($model, $wordsize, $info);
if ($opt_m) {
	die "file not found $opt_m\n" unless -s $opt_m;
	($model, $wordsize, $info) = read_imeter_parameter_file($opt_m);
} else {
	while (<DATA>) {
		my ($word, $score) = split;
		$model->{$word} = $score;
		$wordsize = length($word);
	}
}

################################
#
#   M a i n   L o o p
#
################################

# check for standard input otherwise open regular filehandle
my ($fasta, $input);

if ($FASTA eq '-') {
	$fasta = new FAlite(\*STDIN);
} else {
    open($input,"<", $FASTA) or die "Can't open $FASTA\n";
    $fasta = new FAlite(\*$input);
}

while (my $entry = $fasta->nextEntry) {
	my ($id) = $entry->def =~ /^>(\S+)/;
	my $seq = uc $entry->seq;
	

	# clip sequence to remove donor and acceptor?
	$seq = substr($seq, $donor, -$acceptor);
	
	# loop over input sequence in pentamer windows, and extract score from %pentamer_scores
	my @records;
	for (my $i = 0; $i <= length($seq) - $wordsize; $i++){
	    my $subseq = substr($seq, $i, $wordsize);
		# are we working on reverse strand?
		$subseq = reverse_complement(substr($seq, $i, 5)) if ($opt_r);
		$records[$i]{start}  = $i;
	   	$records[$i]{end}    = $i + $wordsize -1;
		# it's possible that input sequence has ambiguity codes, in which case we can't 
		# calculate a pentamer score, so just set to 0.
		if(defined $model->{$subseq}){
		   	$records[$i]{score}  = $model->{$subseq};			
		} else{
		   	$records[$i]{score}  = 0;
		}
#		print "$records[$i]{start}-$records[$i]{end}) $records[$i]{score}\n";
	}					

	# now we want to make a list of the windows whose average score (per base) exceeds the $cutoff value
	# this loop starts at the middle position of the first window (e.g. position 3)
	# and loops through the middle position of the last window
	# but will calculate the window score from 1st base to end of window (e.g. 1 to 5)
	my @windows = ();
	my $high_scoring_window_count = 0;
	
	for (my $i = 0; $i < @records - $window_size + $wordsize; $i += $window_step){

		my ($start, $end) = ($i, $i + $window_size - 1); 
		my $window_score = 0;
		
		# now loop through all pentamers that comprise the window and add their score to $window_score
	  	for (my $j = $start; $j + $wordsize -1 <= $end; $j++){
		 	$window_score +=  $records[$j]{score};
		}

		# if window score is above cutoff, store details...but store average score per base
 		if ($window_score >= $cutoff) {
       		my $avg_score = $window_score/$window_size;
    		$windows[$high_scoring_window_count]{start}     = $i;
    		$windows[$high_scoring_window_count]{end}       = $i + $window_size - 1;
    		$windows[$high_scoring_window_count]{avg_score} = $avg_score;
    		$high_scoring_window_count++;		    
#			print "$start-$end\tHigh scoring window \#$high_scoring_window_count\tavg_score per base = $avg_score\n";
 		} else {
#			print "$start-$end\n";
		}
	}
		
	################################
	#
	#   F i n d   P e a k s 
	#
	################################

   	my @peak; 
   	my $peak_counter = 0;

    # Genis automatically defines first peak as equal to the first high scoring window. Why?
   	$peak[0]{start}     = $windows[0]{start};
   	$peak[0]{end}       = $windows[0]{end};
   	$peak[0]{avg_score} = $windows[0]{avg_score};

	# loop through remaining high scoring windows  I.e. start at $i = 1 rather than 0
   	for (my $i = 1; $i < @windows; $i++ ){
	#	print "$i) $windows[$i]{start}-$windows[$i]{end}) avg_score = $windows[$i]{avg_score}\n";

		# now ask whether current window is within $gap nt of current peak
    	if ($windows[$i]{start} - $peak[$peak_counter]{end} < $gap){
#			print "\tBEFORE: Peak $peak_counter\t$peak[$peak_counter]{start}-$peak[$peak_counter]{end} $peak[$peak_counter]{avg_score}\n";

			# if window overlaps peak, then change end coordinate of current peak...
        	$peak[$peak_counter]{end} = $windows[$i]{end};

			# also change the score of the peak by making a new average score
    	 	$peak[$peak_counter]{avg_score} = (($peak[$peak_counter]{avg_score} + $windows[$i]{avg_score}) / 2);

#			print "\tAFTER:  Peak $peak_counter\t$peak[$peak_counter]{start}-$peak[$peak_counter]{end} avg_score = $peak[$peak_counter]{avg_score}\n\n";
      	} else {
			# at this point you have defined one peak and can start looking for the next one
			# increment peak counter and set default values of 2nd peak to be that of current window (???)
        	$peak_counter++;
	 		$peak[$peak_counter]{start}     = $windows[$i]{start};
	 		$peak[$peak_counter]{end}       = $windows[$i]{end};
	 		$peak[$peak_counter]{avg_score} = $windows[$i]{avg_score};
      	}
	}

	################################
	#
	#   S c o r e   P e a k s 
	#
	################################
	
	my $imeter2_score = 0;

    for (my $i = 0; $i <= $peak_counter; $i++ ){  		
    	my $peak_score = 0;
		
		# just skip forward if there are no peaks
		next if not defined($peak[$i]{start});
#		print "$i) $peak[$i]{start}-$peak[$i]{end}\n";

	 	for (my $j = $peak[$i]{start}; $j <= $peak[$i]{end} - $wordsize +1; $j++){
			$peak_score +=  $records[$j]{score};
       	}

		# calculate a weighted score based on distance of peak
		# should have two variables here? distance based on start or middle of peak?
		# 1/200 could also be variable
		# include a donor offset in case a large amount of sequence was clipped
        my $weighted_score = $peak_score * exp(-($peak[$i]{start}+$donor) * 1/$weighting_factor); 
#		print "$i) $peak[$i]{start}-$peak[$i]{end}\tavg_score per base = $peak[$i]{avg_score}\tTotal peak score = $peak_score\tweighted score = $weighted_score\n";
	    printf("%s\tIMEter\tpeak\t%d\t%d\t%.2f\t+\t.\t.\n", $id, $peak[$i]{start}, $peak[$i]{end}, $weighted_score) if ($gff);	     
	    $imeter2_score += $weighted_score;
	}
	
	# with large window sizes can end up in situations where individually positive scoring
	# windows can be connected by short regions of negative score. Can end up producing a single
	# large negative peak. So should always set to zero if this happens.
	$imeter2_score = 0 if ($imeter2_score < 0);
	# print out final score
	my $formatted_score = sprintf("%.2f",$imeter2_score);
	print "$id\t$formatted_score\n" if (!$gff);
}

close $input if ($FASTA ne '-');

exit(0);

############################ 
#
#   S U B R O U T I N E S 
#
#############################


sub reverse_complement {
        my ($seq) = @_;
        $seq = reverse $seq;
        $seq =~ tr[ACGTRYMKBDHVacgtrymkdbhv]
                  [TGCAYRKMVHDBtgcayrkmvhdb];
        return $seq;
}


sub read_imeter_parameter_file {
	my ($file) = @_;

	my $info;
	my %model;
	my $wordsize;
	open(IN, $file) or die;
	while (<IN>) {
		if (/^#(.+)/) {
			 $info = $1 if not defined $info;
			 next;
		}
		my ($word, $score) = split;
		$word = uc $word;
		$model{$word} = $score;
		$wordsize = length($word) unless defined $wordsize;
	}
	close IN;
	$info = "" unless defined $info;
	
	return \%model, $wordsize, $info;	
}


exit(0); 

__DATA__
# Tue Jan  7 15:07:34 PST 2014
# build: /Users/keith/Work/Code/IME/ime_trainer.pl -k 5 -p 400 -d 400 -c Athaliana_IME_intron.fa
CGCCG	1.22953648512629
CGATC	1.05461245354295
CGATT	1.03625398431636
CGGCG	0.982759636835548
TCGAT	0.964288118654301
TCCGA	0.892261809503596
TCGCG	0.890909071438347
GATCG	0.872558511203674
TAGGG	0.867923670376819
GGGTT	0.861602930056838
TTCGA	0.853614225351389
CGCGA	0.847351833937376
CGTCG	0.830087669049207
CGACG	0.829707674657411
AGGGT	0.822745275109967
ATCGA	0.811812039338427
CGAAT	0.810244108724747
CCGAT	0.806683868159494
TCGAA	0.789184771054985
AATCG	0.787173377488944
CTCCG	0.776975927412774
CTGGG	0.725197110152717
ATTCG	0.699600149336081
ATCGG	0.692354548717691
CTCGA	0.678062227946179
TCGGA	0.659581441968113
CCGCG	0.651285184121229
TTAGG	0.642001074338184
CGCGT	0.637989361050046
CTTCG	0.635663118017174
CGCGC	0.634956763737185
GCGAT	0.623116282516331
GCTCG	0.618732513572609
CGAGA	0.601537502589247
GTTCG	0.590493673412444
GGCGG	0.588934871904438
TGGGT	0.583453139215453
CGGAT	0.567693293462877
TTTCG	0.565404807935232
TTCGT	0.557022433050123
GATCT	0.55251331649006
AGATC	0.552387009309938
TCGAG	0.545910240677016
GTCGA	0.544450801405781
CCGCC	0.539941428148647
GATTC	0.524513747750296
TCTCG	0.51940347702455
GATTT	0.510587622062
GCCGA	0.507378053004467
TCGTC	0.50512490555298
TCCGG	0.499538020864024
GCCGG	0.49304902471754
GGATC	0.489312062983452
GGCGA	0.487042712882378
TTCCG	0.485744288623816
CGAAG	0.483671027527818
CCGAC	0.482443681319164
ACGCG	0.479819419568003
GAATT	0.475382698932902
ATCCG	0.467161786129698
TCGTT	0.462588259129273
TCGTG	0.45446543203819
CGAAC	0.449234221265342
CGGAG	0.44660186461483
ACGAA	0.445759687303768
GAATC	0.443019779765844
GGATT	0.442293226904464
GTCCG	0.442005997682428
ACGAT	0.441458523798959
CGAAA	0.441233786586153
CCGGA	0.440534774452962
CTCTC	0.436241977156717
TACGA	0.433092136392495
TTCGC	0.431418477493738
TTGGG	0.42772154291065
CCGAA	0.420515932175963
CCGGC	0.42022894468061
GATTG	0.41373487180028
TCGCC	0.408676329157522
ATCGT	0.407426875909313
CGGAA	0.405907165226972
CCCGA	0.400882822043073
GGTCG	0.398781227608071
ATCGC	0.391219856386712
GGTTT	0.389603730768093
CATCG	0.38371202093508
GATCC	0.379729932957898
CGATG	0.379086175212825
CACGA	0.376307433540598
TCGGG	0.374128167987074
TCCGT	0.371672964918573
TCGCT	0.369716064399705
TGATT	0.362536106409375
GACGA	0.361001129774441
TGCGA	0.360035183744888
AGATT	0.356528698461652
GCGAG	0.353868725074883
GAGAT	0.351071114805645
TCTCT	0.350281864145711
CGGTG	0.349609085242245
GTCGG	0.349117397922366
CGTTT	0.348499664522706
TTCGG	0.346148419927597
TTGAT	0.34418550804113
TGGGG	0.343095388098769
CCGAG	0.3422161883393
GCGAA	0.336169308191871
CGAGG	0.328916360519282
CGCTT	0.328594575239907
TTTGA	0.319299688314349
TCTGG	0.318726984501224
AGCGA	0.310552991998994
CTGCG	0.310166269352956
GGGAT	0.309059766646877
ATTGA	0.30895671569511
CGCCA	0.308864054099485
GGGGT	0.307136600344464
CTCGC	0.305339880509763
GAAGA	0.303404675961432
AATTG	0.302099600727873
TGGAT	0.300186328470152
CAATT	0.299088207642473
AATTT	0.298126669532547
CGAGT	0.29617265745668
GGAAT	0.294427047890713
CGTCT	0.289433359606039
GGGAA	0.289190105684371
TATCG	0.28772677800743
TCGGC	0.286924982927385
GGGTC	0.278050895589329
TCCCG	0.275641139380288
TAGAT	0.275537851707394
TGTCG	0.273326188428973
CGTTG	0.272647573695057
CGCGG	0.272533890621763
CGACC	0.271918799995993
CTCGT	0.271515637403945
TCGTA	0.269066250921123
TTGAG	0.268050169702418
TCTTC	0.26632451026818
GGGGG	0.265538623213626
TTTGG	0.263724064593796
CGGGA	0.262672177222738
CGGGG	0.262070054789442
TGGCG	0.261973245362278
TAGGT	0.258232009481115
TGATC	0.25816121290562
AGCTC	0.253006721356248
ATCTC	0.252328355297753
AACGA	0.251831248374828
CGTGA	0.250835944657244
TTGCG	0.250423189016014
CGTGT	0.250080383967262
TTTAG	0.246289334501858
TCGGT	0.244613632840514
CGTTC	0.244105482295246
GGTGA	0.242749325513267
TTGGA	0.241815125143493
GGAGA	0.240478858204632
CAGAT	0.239887028169084
AATTC	0.237892149704273
AGACG	0.237521839062728
CCGGG	0.23583909064108
GAAAT	0.234006937293365
TTGAA	0.232267592547741
TTTTG	0.23084156154927
GATGA	0.229321823800464
AGGTT	0.22897710203808
CTCTG	0.22857353152956
GTGGG	0.227378860409124
TTAGA	0.226868742137259
CTAGG	0.226858165680839
GATTA	0.226696911247093
TGAAT	0.226182345575665
TTCTC	0.225222907735558
GGGGA	0.224693140700591
ATTTG	0.224162829797729
TCTCC	0.223709037404382
GTTGA	0.222967701754262
CGGCC	0.221165499531359
TGGGA	0.22012238864749
TCGAC	0.218169482508381
GTCGC	0.217014833241833
ATTGG	0.216820649849601
ATTAG	0.211135502892541
GAGAA	0.210472922489512
AAAAA	0.209620451625175
ACGGA	0.20699260439434
AACCC	0.206379252524499
ACACG	0.206369023639284
TGCGT	0.2051842872338
GCGGA	0.203900497137139
GCGTT	0.203768305210029
AAATT	0.203289772978537
CGTCA	0.201824954222873
GAGAG	0.194503320613109
AGAGA	0.194440522993134
TCAAT	0.194025353366667
CGATA	0.194023720533974
CGTGG	0.193426098768638
CGTAT	0.191900009778371
TTACG	0.190267851859597
GTACG	0.18995842235662
CGGTC	0.189624535658258
GATCA	0.18785926939511
GGTGG	0.187859138061751
AATCT	0.186001759691247
TCGCA	0.185886525179101
GCGGC	0.185838562844273
AAATC	0.185647048705782
TGAGA	0.185463464690046
ATCTG	0.185102572044817
CCGGT	0.183927777229108
GTCGT	0.183055570506035
CCGTC	0.182197153917313
GGGTA	0.182102404869541
TTTTT	0.182012811760085
GGCCG	0.181035536136267
CTGGA	0.180675169774596
GTTTT	0.179889257314363
AGGGC	0.178853912744146
CGAGC	0.178709041117237
ACCGA	0.177191546869341
ACGAG	0.177000147628345
GTGGA	0.175377559286033
GACGG	0.175202487997579
GCGTC	0.171641025022603
CGTAA	0.169333064154166
CCCGC	0.162013176377046
GGTTC	0.161975515474064
CAACG	0.16177767858965
CCGTT	0.161146203244265
GTTTC	0.159438308681171
GAACG	0.158288816084419
CCTCG	0.15789132468064
TAGCG	0.157595632611488
ATGGG	0.156935656967147
GCCCA	0.155802601808327
GTGAT	0.1496612793696
GTGTT	0.149651225150075
GTGTG	0.148965595368419
AATCC	0.147418736942057
AGTCG	0.146467877642085
TTCAA	0.142225417450808
GAGGT	0.141923584076466
TTGTT	0.13785943579875
TGGAG	0.136839232678124
GGAAA	0.136027322920685
CGTAG	0.135497182938314
AAAGT	0.135460444395028
CGGCT	0.135420759254372
CTTCT	0.135226344807639
GAGGA	0.133616999096883
TGGAA	0.132900337818831
GCGTA	0.132287963554638
TCTGA	0.132100445887097
CGTTA	0.131561413992204
TTTGT	0.131548711144665
GTTTG	0.131353266112011
CTCGG	0.131066263039955
GAGCT	0.130858884187
GGAAG	0.129683449417491
TCAGA	0.129629878928962
AGCTT	0.128815084873552
GGCGT	0.127073011766695
TTGTG	0.127058465649694
CCAAT	0.12457211373854
AGAAT	0.124243122880489
GGTTG	0.124053102546883
ATTTT	0.122254933346316
GAGTT	0.121668528272317
CTCAA	0.121630412352576
TGTGT	0.120146906289177
CCACG	0.118391886420378
AGGAT	0.117301048982312
GGAGG	0.117139024123683
AAGCT	0.114924044479334
CGGAC	0.112934119969519
CGCAA	0.112634091302492
AAGAT	0.109062356526795
GTGAA	0.107847975582691
ATTTC	0.10594526858725
TAATT	0.103831990565579
TTGGT	0.103550288913271
TGAAA	0.101484307384445
CGACT	0.101074515154586
ACTCG	0.101031236059415
TCCAA	0.100761182968043
CAAAG	0.100241874635534
AATGG	0.100236332586806
TAGGA	0.0999792256867731
GGTAA	0.0989727044765761
AGGGA	0.0981987379493336
GAAAA	0.0980334341329044
TGTTG	0.0980207398582859
AATTA	0.0951135507263836
TAATC	0.0935344137954181
AAAGG	0.0933548802798084
AAAAG	0.0930508947850625
GTCTC	0.09303155416396
TCAAA	0.0915344267890845
GTTTA	0.0910594455228579
TCCGC	0.0905360568788756
CCCTA	0.0889832659171105
GTTCT	0.0879100734111512
GTTGT	0.0854063518147172
GCTTC	0.0852331907168705
ATACG	0.0829090803393189
AGAAG	0.0814888670626812
TGAGG	0.0805295833054411
TGTGA	0.0801481367809795
GCGCG	0.0798888126793671
CTCCA	0.079760006372341
GGGCT	0.0797461481511035
TTAGC	0.0794134862105495
AGTTT	0.0789728938081413
GGTTA	0.0782452552667962
CCCAA	0.0754478841832877
TGGTT	0.0745379280795677
TGTTT	0.0744435448124539
CTCTT	0.0742987934502127
AAGAG	0.07351928780364
TGTGG	0.072298136521186
TCACG	0.0704972290245619
TGAAG	0.0704818330976197
TGTTC	0.0702743885189083
TGGTG	0.0694732199107534
CAATC	0.0686826454350412
TCTGT	0.0678434710187739
TCCTC	0.0667262120240582
CCGTA	0.0664034103220795
ATTCA	0.0662916062785406
AGGAA	0.0635564540845036
CGGTT	0.0620007663910614
AGGCG	0.0617262348940934
AAAAT	0.0615137641582937
TAGCT	0.0614804368981354
CTACG	0.0610459375005652
CAAAA	0.0607174527133287
ACGAC	0.0603648000856031
CTAGA	0.0596224447999705
GAGTG	0.0595060938064707
TAAAG	0.0585327861310956
CCAGA	0.0584231722992819
TAGTG	0.057928310506495
AAGGG	0.0578169674519074
GAAAG	0.0577524384901022
GAGGG	0.0573104333452204
GAAGC	0.0570560300317408
AAACC	0.0557808486180388
TAGAA	0.0551582017796698
CCCCG	0.0546155764656589
CTGAG	0.0544942759018473
TGATG	0.0524989822812623
GTAGA	0.0519112378781718
ACGGC	0.0516330124948191
AGTGA	0.0515407462298513
AAGGT	0.0513810445183373
AGAAA	0.0508554659007827
CACTC	0.0496572946857147
AAACG	0.0483298259145272
TTAAT	0.0483104118563492
AGGTA	0.0472168888374343
ATAGA	0.0468283894473025
TAGAG	0.0466930232192995
GAAGT	0.046566236575513
AAGTT	0.0449619204169516
AATCA	0.0446364828815541
AAAGA	0.0442514802821444
AGCCG	0.0429376765064755
ATCTA	0.0423359275208576
CCGTG	0.0413293851175116
ATCAA	0.0408540332517074
CTGAT	0.0405932538895376
AACGG	0.040430202876444
ACCGG	0.0375035519061854
ACGCC	0.0354946933209138
CCCCA	0.0340265147706791
GACCG	0.0326668027567615
AGGTC	0.0322925703233096
TACGT	0.0318165489730036
TGAGT	0.0313516171434848
AAGAA	0.031281656873117
AAAGC	0.0311081754603048
GATGT	0.0295918747151849
ATGGA	0.0279463916836534
CCAAA	0.0272724185603987
ATTGT	0.0266155424389718
AGATG	0.0264392803054502
CCCGG	0.0248110583221525
CACCG	0.0242758869396408
ATGAT	0.0240235289565789
AGGAG	0.0239971052231409
CGGGT	0.0238613331009106
GATAA	0.0230796252125686
GCTCT	0.0222702033051553
TTCTT	0.0221103702300687
GGCTC	0.0206568994908799
TGGGC	0.0204476352438379
CTTTG	0.020120074298417
ACGTT	0.0191527377745855
TTAGT	0.0191494784584811
TTTCT	0.0191458583421749
TTAAA	0.0183486488272615
CGTAC	0.0182844658647076
TTCTG	0.0177717096454183
GAGTC	0.0162156308260306
AGAGT	0.0161190138197908
AGAGG	0.0153643022674757
TCTAG	0.0151427182192105
GAAAC	0.0144770529302022
GCTTT	0.0130244801276513
ACGTA	0.0129782866229455
GCCGC	0.0125335448776025
CACGC	0.0123369723336613
CACAC	0.0122104690637143
ATTCT	0.0119033459283314
CTCTA	0.0117993724904491
CGACA	0.0114756566242332
AGTGT	0.0109976813304246
ACCCT	0.0102957340467744
TAACG	0.00932731520236129
CAAAT	0.00839799852748125
ATCCA	0.0078111346351991
ATGAA	0.00762171290093908
CGCAT	0.00690704017144478
TCATC	0.00578609313181452
TACGC	0.00530131652065332
CTTAG	0.00520973075497045
ACAAA	0.00452461921261013
TCTCA	0.00437204576820442
GCGAC	0.00390980309233203
TTTAA	0.0038656313549677
GATAG	0.00316851356515023
TAAAA	0.00312070172019736
GATGG	0.00310743149830708
GTTCC	0.00130965889609951
TTTTA	0.00118900994999074
GGAGC	-0.00100763599595366
ATTTA	-0.00151960017164508
GTTAG	-0.00414400766612858
TCAGG	-0.00469726781540874
GCTTG	-0.00727632293458482
AACAA	-0.00787640195840067
CAGAG	-0.00859001103612192
AACGC	-0.00901985635948376
GGCCC	-0.0121788682317177
CGGTA	-0.0132818461454485
GAGAC	-0.0133531862658485
AAAAC	-0.0136988670956239
TACCG	-0.0153348021364578
GTTAA	-0.015341065668703
ATAAA	-0.0154790267396636
ATGCG	-0.0155392388157726
GGATG	-0.0156312305357127
GTGGT	-0.0167144854462542
CTAAT	-0.0174155165978647
AGTTG	-0.0178216887716889
TCTAA	-0.0189364551293179
AAGCG	-0.0199577530268049
TACGG	-0.0202478586060829
ACCCG	-0.0216017324997707
GACGC	-0.0219260004306844
AAGGA	-0.0223105718278702
CGCAC	-0.0223493812513707
CTTGA	-0.0228070925302023
TCTTT	-0.0229976384365328
TCAAG	-0.0231508214044025
TAGTT	-0.0242798482079295
ATTAA	-0.0272787711646516
CCTAA	-0.0275839893024665
TTGCT	-0.028392955272222
ACGCA	-0.0284365006046782
TTAAG	-0.0288992268425711
CACGT	-0.0293851609781881
GCCGT	-0.0309286698120752
AGTTC	-0.0314638135873457
GGAAC	-0.0336524262941389
AGGTG	-0.0339008445517893
GCTTA	-0.0339345492974191
TTTTC	-0.0347241945510499
CTGTG	-0.0348750562775224
GGTGT	-0.0352619662187803
CGTCC	-0.0364759440124174
TGAGC	-0.0369494378989541
GAACC	-0.0372864335369573
GGATA	-0.0376052664601923
GAAGG	-0.0391309726390933
ATTCC	-0.0408889455554114
AGTCT	-0.041219646941248
AACCG	-0.0421247290822522
GACGT	-0.0422260423042902
ACAAG	-0.0428982609779167
TCTAT	-0.0429106373457963
CGCCT	-0.0436755201126941
ATCTT	-0.0438239386975061
ACTCT	-0.0440323611123366
GTCTT	-0.0445103301334148
GTAAT	-0.0446142206883162
ATGAG	-0.0461254235066333
GCTCA	-0.0463023068803825
GGTCT	-0.0478055714958579
AAATG	-0.0483070188027793
TGACG	-0.0489829750058095
GGACG	-0.049019429606812
CAGCT	-0.0493439964999854
GTTGG	-0.0497476294137691
CCTCT	-0.0505314028755423
ACCCA	-0.0505531720750092
CTGTT	-0.0507582374291715
TCCCC	-0.0522341560505611
CTGAA	-0.0522658115848748
CTCAC	-0.0533205967745243
CCCCC	-0.0537060252852235
GGTAG	-0.0538890225551757
TTTAT	-0.0540568916573785
GTTCA	-0.0542189446994843
AACGT	-0.0543228107612423
CGGCA	-0.0560388561450289
AAGTC	-0.0561685527402432
GAATG	-0.0563302514759758
TTCTA	-0.0568006750233141
ATCAG	-0.0571101840359141
TTCAC	-0.0583222316595939
ACGGT	-0.0587350283681134
GTGTA	-0.0592448515170619
GACTT	-0.059946730607943
ATAGG	-0.0606234609429061
AGTGG	-0.0606723180987364
AATGA	-0.0610489940233746
GGGCC	-0.0612224912582087
TCTAC	-0.0614131305134063
AGCTG	-0.0617219071685312
TTCAT	-0.0618940870180093
ACCAA	-0.0639198381472227
AGCTA	-0.0641550519344515
CTAAA	-0.0646526971462933
TAAAT	-0.0647832318304521
CTCCT	-0.0648194279359646
CTTCA	-0.0648665290246
CGCTC	-0.0649239025592038
ACAGA	-0.0650388480355375
CAAGT	-0.0658129892656796
CAAGG	-0.0668287976016202
TGTAA	-0.0683159921393544
AACTC	-0.0683940468184623
TAAGA	-0.0694338130811398
GGAGT	-0.0711180237591303
CAAGA	-0.0716768302268826
GACTC	-0.0747729433887259
CTTAA	-0.075163567532304
TTTCA	-0.0751796044589514
GAACA	-0.0760661974872252
ATGTG	-0.0770680561346459
GTAGT	-0.0785121920043315
CTTTT	-0.0787233558886469
CGCTA	-0.078856389632878
TCAGC	-0.0801135412212928
TGCTT	-0.0802209800739416
GGCTT	-0.0805468208024036
AGTAA	-0.0812358110523695
CTTTA	-0.0815830290788912
ACGTC	-0.0830913032875491
CCTCC	-0.0832024957046343
GGGCA	-0.0842584676211274
GCGTG	-0.0846159129786923
AAACT	-0.0847523920767566
ATCCC	-0.0848231928800294
ATTGC	-0.0851312532381063
CAAAC	-0.086020274124944
ATCAT	-0.0876207651261576
TGCTC	-0.0879932771739004
AGAGC	-0.0880027916104171
GACAA	-0.0885349450885752
TTATC	-0.0893774740231452
GCTCC	-0.0897197735756064
TTTGC	-0.0899144526190125
ATAAG	-0.0900361887629454
TATAG	-0.0902387860165978
GCAAT	-0.0911743281305955
TTATG	-0.0916244399516645
GACCC	-0.0916784143709912
CTTGG	-0.0921025545819692
AGCGG	-0.0924507416962453
ACGTG	-0.0931923813166331
ACACA	-0.0945219698300412
CATTG	-0.0945325367948206
AATGT	-0.0968389357174533
GAATA	-0.0977652360328013
TCCAC	-0.0978829123426893
TCTTG	-0.0979726389658525
TCACT	-0.0989309692100311
GGTAT	-0.0990264859003301
CTTTC	-0.0991471475724334
CACAA	-0.0997109503475172
CAGGA	-0.0999927157953686
AGTAG	-0.101030531020655
CGCTG	-0.101785951540754
GGACT	-0.102753137620511
TGTTA	-0.102910582971166
CAGTG	-0.103183868633047
AAACA	-0.103284015229645
CCCAC	-0.103794113093729
TTGTA	-0.103987938877616
ATATA	-0.104979237308282
GTTGC	-0.107152027892111
AGATA	-0.107985969808459
TATTG	-0.1081182033115
CGTGC	-0.108737494436676
AGAAC	-0.109170640865744
AACAC	-0.109673614353918
GTCAA	-0.109690222877919
TGTCT	-0.110017672253945
ATAAT	-0.110365432791915
TATGA	-0.110427435817614
ATAGC	-0.111040942110977
CTAAG	-0.111213958635742
TCTTA	-0.111263979961942
TTGAC	-0.11152239676842
CAATG	-0.111785395268452
GCAAA	-0.112388734611759
ATTAC	-0.113094153420488
CTTCC	-0.113234454580224
GCCCG	-0.113590916741842
GTAAA	-0.114168911300145
TTCCT	-0.114457149426586
CTTGT	-0.114518434304904
GAGGC	-0.114779586207385
ACGCT	-0.115147967278569
CGCAG	-0.115436405439621
ACAAT	-0.115816432386714
CAGAA	-0.115990980575547
TAGAC	-0.116011047696255
TTGTC	-0.116953875376965
TTTCC	-0.117464677288591
AATAA	-0.118097540353669
GGTCA	-0.11827592617156
TGCCG	-0.1191531213797
GGGTG	-0.119182534422462
ATGGT	-0.119650300865321
CCTAG	-0.121023881246629
TCCTT	-0.121161208631672
AACCA	-0.122946960562762
TATAA	-0.123278994943963
AGCAA	-0.123613897626638
GGGAC	-0.123666966644225
ACCGT	-0.123743163649109
CCTTC	-0.125183390337929
TACAA	-0.125481344587037
ACTAG	-0.12604153005715
TGATA	-0.128481551869246
CCATT	-0.128907007840515
GTATC	-0.130257810232095
ATCAC	-0.131016147014932
CTAGT	-0.131748442191513
GTTAT	-0.131847775619523
GTGTC	-0.132047944703639
TAAGG	-0.133273282603542
TGGTA	-0.133549935091311
TCAGT	-0.133685020382845
ACTTT	-0.134651840776256
ATAGT	-0.134658270905278
TAAGC	-0.134814615409442
GCTGG	-0.13488734604581
GTGAG	-0.135173675893279
TAGGC	-0.135375496538961
TCACA	-0.137789993318739
CCCGT	-0.139249163241622
GGGCG	-0.140662261832913
TAAAC	-0.140876823400822
TGCCC	-0.141478603256316
GAGTA	-0.141576879529535
CGCCC	-0.141614976019876
AAGAC	-0.141664588545682
ATGTT	-0.141886714815148
CCCTC	-0.142014183756004
TAATG	-0.142054765209146
TGTAT	-0.144148786167764
TCATG	-0.144837123182631
CAAGC	-0.144912517283019
AGACT	-0.145894844074746
CATAA	-0.145897616368015
GTCTG	-0.146555687702343
CACGG	-0.146790967060179
GATAC	-0.147090121658291
ACTTG	-0.14760443646969
GAACT	-0.147694744798956
GTCTA	-0.147963925960419
TCACC	-0.148649909827439
CACCA	-0.148842834765965
TTGGC	-0.149381354910134
CCAAG	-0.149934890076515
GGTCC	-0.150289353623676
CAACA	-0.150542516686146
GCGGT	-0.150698970669569
ATCCT	-0.151022594013582
AGGCT	-0.151420402909949
CTCCC	-0.152826561652071
CAGGG	-0.153469403655983
TGTAG	-0.155639549359818
GAGCG	-0.155651653561783
TCCAT	-0.155911437324751
ATGTA	-0.156007084904809
TATGG	-0.156791603430185
CTCAG	-0.156816280490652
TCAAC	-0.157062240736262
GCTGA	-0.15730264527219
TTATT	-0.157500956767965
TCTGC	-0.158107933760944
TAGTC	-0.1581614311624
CCTTT	-0.159123709058031
CTATT	-0.159918319695185
AAGTA	-0.160881071392722
TAGTA	-0.161391589376977
TCATT	-0.161409566728463
CCACA	-0.163113888332367
GGGAG	-0.16313157004381
GCAGA	-0.163599523638475
CTGGT	-0.164180013926735
CATAG	-0.165274916315739
CTATG	-0.165987047643328
AAGTG	-0.166725992298991
AATAG	-0.16672894575743
ACACT	-0.168524968319996
GCTAA	-0.168762274074205
ATACA	-0.168922053121997
AGACA	-0.169807476210466
CATTT	-0.170450820963706
CTATC	-0.171908494355203
ATTAT	-0.172252933259377
CAGGT	-0.172582625909167
TGAAC	-0.173762039406498
AGACC	-0.174123222640794
GGCAA	-0.174626360798978
TTTAC	-0.174638637798734
TTATA	-0.175984204254034
AGTTA	-0.176610157104481
CACTG	-0.176880399557132
GATAT	-0.176897029152937
TTCCC	-0.17710194887381
TTCCA	-0.178556396404889
GCACG	-0.180299638931199
TATAT	-0.181207936231573
GGCTA	-0.183231547162072
AACTT	-0.183441534558832
CATGA	-0.183442169379315
GATGC	-0.183634158554234
GGTAC	-0.185324407204682
ACTCA	-0.188827793225045
CATCT	-0.190429621543471
TATCA	-0.191588622423148
GCGCA	-0.19181992672026
TCATA	-0.19277243201041
TGGCT	-0.19363162211441
TACAC	-0.194857055677675
GTAAC	-0.197001428056398
TGGTC	-0.197153436660025
GCGCT	-0.197772569149832
GTATA	-0.198774794654517
TACTC	-0.198801606165893
ACAAC	-0.199289062027788
TATCT	-0.200219106513368
GAGCA	-0.202779398268401
CATGG	-0.204601338842843
TGGAC	-0.206046848614875
ACTCC	-0.208096952685974
AACCT	-0.208635505269362
AGGAC	-0.209088860406709
GCGCC	-0.209088860406709
TAACC	-0.209294767518643
AGTCA	-0.2093458179934
GTGGC	-0.209489144257722
CTACT	-0.21017774826062
GTAGC	-0.210231812194087
AGCCC	-0.210564275063069
TGCAA	-0.210625275818749
CATGT	-0.211416370561421
CCATC	-0.211661425394232
ACATA	-0.212635308374082
TTACT	-0.213521725613161
ACTAA	-0.213683902532312
AGCAG	-0.214524886996752
AGGGG	-0.215103703236947
GCAGC	-0.216200084980129
GCTAG	-0.216666365657847
CTAGC	-0.218603662706853
GACAC	-0.219273758621298
TGACT	-0.219906263718408
CCACC	-0.220422677236549
TATTA	-0.223979310663005
TTCAG	-0.224655962224873
AAGCC	-0.22478248802039
AACTA	-0.225491980216969
CCCAT	-0.2256459146026
AAATA	-0.225762770253025
CCACT	-0.227789686746836
CTATA	-0.22848084357142
GTATT	-0.230659054357059
GTGCG	-0.23191640527987
TATGT	-0.232182765194095
TATTT	-0.232306407621293
ACCCC	-0.232350991524767
GGCGC	-0.233293239743177
GAGCC	-0.233856077959968
CATCA	-0.234070465429154
AACAG	-0.234728786919494
GCTAT	-0.236391220356774
GGACC	-0.236840375533676
AGCGC	-0.236877577092216
CTCAT	-0.237913973762991
GCAAG	-0.238841109670422
CCAAC	-0.239659251356053
ACTGA	-0.239772230017448
CACAT	-0.24113634818181
ACCTA	-0.241150284516793
TGTGC	-0.242334886151431
CACTA	-0.242383833825496
GACCA	-0.242512884823744
TACTT	-0.242641751183851
GCCAA	-0.243102824490506
AGCGT	-0.245532492246092
ACCAC	-0.245692601559292
CTACA	-0.245733765765737
TTAAC	-0.245740083829193
CCCAG	-0.245802602876027
TAATA	-0.24613402011147
TCCTA	-0.246415593592086
CCCTT	-0.248245695371744
TATTC	-0.248357654657208
TACTA	-0.248399476286447
GGACA	-0.248709498683444
GTGCT	-0.24888397080221
CCGCT	-0.250134586243213
ACAGT	-0.250250240779953
CAATA	-0.250377909930381
TTACC	-0.250805141776279
TATAC	-0.250978337393079
TCCCA	-0.251053740962545
AAGCA	-0.252265892129799
CAGTT	-0.254437546589459
ATAAC	-0.254647836539583
GACCT	-0.256187544253966
TTACA	-0.258311075601382
AGTAT	-0.258500202883486
GACTA	-0.259572061398883
CAGTC	-0.260178381781263
ATGTC	-0.260757951169281
TAGCA	-0.262153003456726
AGTCC	-0.262382690662544
CCTCA	-0.262517694308339
GTCAG	-0.262787708864203
AATAT	-0.264004270560966
GTTAC	-0.264718437483892
AGCCA	-0.264721210017529
ACCTT	-0.266593956381725
ACATT	-0.268349634756101
TACAT	-0.269820799417367
TCCCT	-0.272255756584439
TAACA	-0.27442390898169
CAGAC	-0.275301736339743
GCCTC	-0.277277521939524
GGCCA	-0.279108536899367
CTTAT	-0.279849621523832
CACTT	-0.282019392089985
ATGGC	-0.282140671787921
GTGAC	-0.282327866236782
GGGGC	-0.282866786546257
ACTTC	-0.283020844214474
GCCCC	-0.2832084711844
TGGCC	-0.283760724324642
TAAGT	-0.28377134059004
GTCAC	-0.283869438463332
ATATG	-0.284467004159879
CCTTA	-0.285726674448825
ATATT	-0.285986411429013
CTTAC	-0.286166681148062
GCTAC	-0.288515990155065
AACAT	-0.289002761178582
TGTAC	-0.289683265729446
GTCCT	-0.290592183485437
GCATT	-0.290907345765445
TGCGG	-0.292418649367899
TACCC	-0.292665355277963
AAGGC	-0.295102996325515
CAGTA	-0.295138539487065
CAGCC	-0.298358915587249
ACCAG	-0.298565663952546
CACCC	-0.298825308299573
ACTAC	-0.299835447404229
ACCAT	-0.301320219966315
TTGCA	-0.302564050199186
TGACC	-0.305917507810382
ATATC	-0.30684628582044
CCAGG	-0.308534693994902
CCCCT	-0.308947277829911
ACTGT	-0.310251952406839
CCAGC	-0.310834178136528
CAACT	-0.311210014671853
ACTAT	-0.312609652289942
CTACC	-0.313943250701392
GTACT	-0.314803147721388
CATTA	-0.315846385826605
GGCTG	-0.317522477834611
ACCTC	-0.317860516226942
GCCAT	-0.317958302729191
TAGCC	-0.318284305772691
GTACC	-0.31836612379288
TGCGC	-0.318832692313276
CATTC	-0.318906940498421
ACACC	-0.32006123871791
GCCCT	-0.32269694555322
ACCGC	-0.322886412365613
AGTAC	-0.323658327260034
ACTGG	-0.323918782899589
TAACT	-0.324395912257375
CTGCT	-0.328340245973925
CACAG	-0.328380837076878
TACCA	-0.328429477965107
TATCC	-0.329428857355537
ACTTA	-0.331715379779285
CCAGT	-0.332418078046409
CCATG	-0.333299310685043
CAACC	-0.333734378624545
CCGCA	-0.335476534582001
CCTTG	-0.335525527604742
GCCAC	-0.33566091633711
AATAC	-0.335763848754345
CTGTA	-0.335808012540023
CATAT	-0.336844935272713
CCTGA	-0.338383958755074
CATAC	-0.339042890667941
GCGGG	-0.339512489302018
GTCAT	-0.339815473812373
TGCAT	-0.339864182356865
GTGCA	-0.340915389119929
TCCTG	-0.341960239521619
AGGCA	-0.344080027409058
ACATG	-0.347749668045538
ATGAC	-0.347974380740148
CTGTC	-0.348174566003367
AATGC	-0.348319814537164
GGCAG	-0.348455128173833
CCATA	-0.351391209637406
GCATG	-0.351459544690754
GACTG	-0.352642802763226
AGCCT	-0.352958020366969
GACAT	-0.353686111662612
CATCC	-0.354465176668492
CCTGG	-0.354869035212387
GCAAC	-0.356097571516611
TTGCC	-0.357777597274267
CAGCG	-0.358268686840429
ACGGG	-0.360578897383397
ACATC	-0.362104096512119
AACTG	-0.362961762536273
GTAGG	-0.363384103205246
CTAAC	-0.367061455011812
GCCTT	-0.371266077543997
GCAGG	-0.372009133272523
GTACA	-0.373590844016292
ATACT	-0.376347062337281
TGCTA	-0.376577628785433
TCCAG	-0.376577918824359
GCTGT	-0.37719466897978
GGTGC	-0.37954280595793
CCTAT	-0.387904339975259
GTCCA	-0.388496436225524
TGACA	-0.389791482493841
GCTGC	-0.391677269505322
GTCCC	-0.392237878806297
GCATC	-0.392480975871887
TGTCC	-0.393983247595458
TGTCA	-0.400199279493973
CTTGC	-0.400554677669157
GCATA	-0.40989384828568
GGCCT	-0.411777514921859
ATGCT	-0.412105096206262
GTAAG	-0.412329384257315
TACTG	-0.416139959621501
AGCAT	-0.417501526649112
TACCT	-0.417933476651913
GTATG	-0.427859458332733
TACAG	-0.434854703473241
ATGCA	-0.436808631505375
TGCAG	-0.440836230205905
GGCAT	-0.441543016044308
CACCT	-0.44415977998584
TGCTG	-0.445123216855039
GCAGT	-0.449696032868376
AGCAC	-0.453331833029176
AGTGC	-0.455597264439694
TGGCA	-0.4557761520426
AGGCC	-0.46327107523988
GACAG	-0.465465129132487
ACAGG	-0.467574004999689
TATGC	-0.469839592643938
CCTAC	-0.481596959298944
GCCTA	-0.481732795384439
ATACC	-0.481796779916093
CTGCA	-0.491676909991263
GGCAC	-0.496906367170391
CGGGC	-0.497095630618265
GCACA	-0.500713356117383
ACAGC	-0.512148213802059
GTGCC	-0.515973350720591
CAGCA	-0.534329490477724
TGCCT	-0.554804733450512
ATGCC	-0.563378401769403
CCCTG	-0.56987401806208
GCACC	-0.576536050598413
ACCTG	-0.579556571459419
CTGGC	-0.586716054319639
CAGGC	-0.591521856850193
TGCCA	-0.592310206436399
CCTGT	-0.613436053359657
CCTGC	-0.62299941260448
CTGCC	-0.624597738524427
GCACT	-0.62628994220081
CATGC	-0.63580782294263
CTGAC	-0.636536198351181
GCCAG	-0.678426101680272
TGCAC	-0.693100495859412
GCCTG	-0.704382496265196
ACTGC	-0.733790381645487
