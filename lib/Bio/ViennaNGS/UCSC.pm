# -*-CPerl-*-
# Last changed Time-stamp: <2014-12-11 16:55:27 mtw>

package Bio::ViennaNGS::UCSC;

use Exporter;
use version; our $VERSION = qv('0.12');
use strict;
use warnings;
use Template;
use Cwd;
use File::Basename;
use IPC::Cmd qw[can_run];
use File::Share ':all';
use Path::Class;
use Data::Dumper;
use Carp;


our @ISA = qw(Exporter);

our @EXPORT_OK = qw( make_assembly_hub  );

our @EXPORT = ();


#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#
#^^^^^^^^^^^ Subroutines ^^^^^^^^^^#
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#

sub make_assembly_hub{
  my ($fasta_path, $assembly_hub_destination_path, $base_URL, $log) = @_;
  my ($basename,$basedir,$ext);
  my $this_function = (caller(0))[3];

  #check arguments
  croak ("ERROR [$this_function] \$fasta_path does not exist\n") 
    unless (-e $fasta_path);
  croak ("ERROR [$this_function] \$assembly_hub_destination_path does not exist\n") 
    unless (-d $assembly_hub_destination_path);
  croak ("ERROR [$this_function]: no URL (network location for upload to UCSC) provided") 
    unless(defined $base_URL);

  if (defined $log){
    open(LOG, ">>", $log) or croak $!;
  }

  unless ($base_URL =~ /\/$/) { $base_URL .= "/";}

  my $tmp_path = dist_file('Bio-ViennaNGS', "hub.txt" );
  ($basename,$basedir,$ext) = fileparse($tmp_path,qr/\..*/);
  my $template_path = dir($basedir,"template-AssemblyHub");

  croak ("ERROR [$this_function] template directory not found\n") 
    unless (-d $template_path);
  my $faToTwoBit_path = can_run('faToTwoBit') or
    croak ("ERROR [$this_function] faToTwoBit is not installed!");
  my $big_bed_info_path = can_run('bigBedInfo') or
    croak ("ERROR [$this_function] bigBedInfo is not installed!");

  # bedfiles path
  my $bedFileDirectory = dirname($fasta_path);
  my @parsedHeader = parse_fasta_header($fasta_path);
  my $unchecked_accession = $parsedHeader[0];
  #print $unchecked_accession;
  my $scientificName = $parsedHeader[1];
  #print $scientificName;
  my $accession = valid_ncbi_accession($unchecked_accession);

  #create assembly hub directory structure
  my $assembly_hub_name = "assemblyHub";
  my $assembly_hub_directory = dir($assembly_hub_destination_path, $assembly_hub_name);
  my $genome_assembly_name = $accession;
  my $genome_assembly_directory = dir($assembly_hub_directory,$genome_assembly_name);
  mkdir $assembly_hub_directory;
  mkdir $genome_assembly_directory;

  #2-bit fasta file conversion
  my $modified_fasta_path = $assembly_hub_directory."/".$accession."fa";
  modify_fasta_header($fasta_path,$modified_fasta_path,$accession);
  my $twoBitFastaFilePath = $genome_assembly_directory ."/" . "$accession" . ".2bit";
  my $full_path = can_run('faToTwoBit') or die 'faToTwoBit is not installed!';
  my $fastaToTwobit_cmd = $faToTwoBit_path . " " . $modified_fasta_path . " " . $twoBitFastaFilePath;
  system($fastaToTwobit_cmd);

  #template definition
  my $template = Template->new({
                                INCLUDE_PATH => ["$template_path"],
                                RELATIVE=>1,
  });

  #construct hub.txt
  my $hubtxt_path = $assembly_hub_directory . "/hub.txt";
  my $hubtxt_file = 'hub.txt';
  my $hubtxt_vars =
    {
     hubName => "$accession",
     shortLabel => "$accession",
     longLabel => "$accession",
     genomesFile => "genome.txt",
     email => "email",
     descriptionURL => $base_URL . "description.html"
    };
  $template->process($hubtxt_file,$hubtxt_vars,$hubtxt_path) || die "Template process failed: ", $template->error(), "\n";

  #construct genome.txt
  my $genometxt_path = $assembly_hub_directory . "/genome.txt";
  my $genometxt_file = 'genome.txt';
  my $genometxt_vars =
    {
     genome => "$accession",
     trackDb => "$accession/trackDb.txt",
     groups => "$accession/groups.txt",
     description => "$accession",
     twoBitPath => "$accession/$accession.2bit",
     organism => "organism",
     defaultPos => $accession,
     orderKey => "10",
     scientificName => "$scientificName",
     htmlPath => "$accession/description.html"
    };
  $template->process($genometxt_file,$genometxt_vars,$genometxt_path) || die "Template process failed: ", $template->error(), "\n";

  #construct description.html
  my $description_html_path = $genome_assembly_directory . "/description.html";
  my $description_html_file = 'description.html';
  my $description_html_vars =
    {
     imageLink  => "imageLink",
     imageSource => "imageSource",
     imageAlternative => "imageAlternative",
     taxonomicName => "taxonomicName",
     imageOrigin => "imageOrigin",
     imageOriginDescription => "imageOriginDescription",
     ucscId => "ucscId",
     sequencingId => "sequencingId",
     assemblyDate => "assemblyDate",
     genbankAccessionId => "genbankAccessionId",
     ncbiGenomeInformationLink => "ncbiGenomeInformationLink",
     ncbiGenomeInformationDescription => "ncbiGenomeInformationDescription",
     ncbiAssemblyInformationLink => "ncbiAssemblyInformationLink",
     ncbiAssemblyInformationDescription => "ncbiAssemblyInformationDescription",
     bioProjectInformationLink => "bioProjectInformationLink",
     bioProjectInformationDescription => "bioProjectInformationDescription",
     sequenceAnnotationLink => "sequenceAnnotationLink"
    };
  $template->process($description_html_file,$description_html_vars,$description_html_path) || die "Template process failed: ", $template->error(), "\n";

  my $groups = make_group("annotation", "Annotation", "1", "0");

  #construct group.txt
  my $group_txt_path = $genome_assembly_directory . "/groups.txt";
  my $group_txt_file = 'groups.txt';
  my $group_txt_vars = 
    {
     groups  => "$groups",
    };
  $template->process($group_txt_file,$group_txt_vars,$group_txt_path) || die "Template process failed: ", $template->error(), "\n";

  my @trackfiles = retrieve_tracks("$bedFileDirectory", $base_URL, $assembly_hub_name);
  my $tracksList;
  foreach my $track (@trackfiles){
    my $trackString = make_track(@$track);
    $tracksList .= $trackString;
  }

  #construct trackDb.txt
  my $trackDb_txt_path = $genome_assembly_directory . "/trackDb.txt";
  my $trackDb_txt_file = 'trackDb.txt';
  my $trackDb_txt_vars = 
    {
     tracks  => "$tracksList"
    };
  $template->process($trackDb_txt_file,$trackDb_txt_vars,$trackDb_txt_path) || die "Template process failed: ", $template->error(), "\n";

  if (defined $log){
    close(LOG);
  }
}

sub retrieve_tracks{
  my ($directoryPath,$base_URL,$assembly_hub_name) = @_;
  my $currentDirectory = getcwd;
  chdir $directoryPath or die $!;
  my @trackfiles = <*.bb>;
  my @tracks;
  foreach my $trackfile (@trackfiles){
    my $filename = $trackfile;
    $filename =~ s/.bb$//;
    my @filenameSplit = split(/\./, $filename);
    my $accession = $filenameSplit[0];
    my $tag = $filenameSplit[1];
    my $id = lc($tag);
    my $track = "refseq_" . $id;
    my $bigDataUrl = $base_URL . $assembly_hub_name ."/". $trackfile;
    my $shortLabel = "RefSeq " . $tag;
    my $longLabel = "RefSeq " . $tag;
    my $type = "bigBed 12 .";
    my $autoScale = "off";
    my $bedNameLabel = "Gene Id";
    my $searchIndex = "name";
    my $colorByStrand = "100,205,255 55,155,205";
    my $visibility = "pack";
    my $group = "annotation";
    my $priority = "10";
    my @track = ($tag,$track, $bigDataUrl,$shortLabel,$longLabel,$type,$autoScale,$bedNameLabel,$searchIndex,$colorByStrand,$visibility,$group,$priority);
    my $trackreference = \@track;
    push(@tracks, $trackreference);
  }
  chdir $currentDirectory or die $!;
  return @tracks;
}

sub make_group{
  my ($name, $label, $priority, $defaultIsClosed) = @_;
  my $group ="name $name\nlabel $label\npriority $priority\ndefaultIsClosed $defaultIsClosed\n";
  return $group;
}

sub make_track{
  my ($tag, $track, $bigDataUrl, $shortLabel, $longLabel, $type, $autoScale, $bedNameLabel, $searchIndex, $colorByStrand, $visibility, $group, $priority) = @_;
  my $trackEntry ="#$tag\ntrack $track\nbigDataUrl $bigDataUrl\nshortLabel $shortLabel\nlongLabel $longLabel\ntype $type\nautoScale $autoScale\nbedNameLabel $bedNameLabel\nsearchIndex $searchIndex\ncolorByStrand $colorByStrand\nvisibility $visibility\ngroup $group\npriority $priority\n\n";
  return $trackEntry;
}

sub valid_ncbi_accession{
  # receives a NCBI accession ID, with or without version number
  # returns NCBI accession ID without version number
  my $acc = shift;
  if ($acc =~ /^(N[CST]\_\d{6})\.\d+?$/){
    return $acc; # NCBI accession ID without version
  }
  elsif ($acc =~ /^(N[CST]\_\d{6})$/){
    return $1; # NCBI accession ID without version
  }
  else {
    return 0;
  }
}

sub parse_fasta_header{
  my $filepath = shift;
  open my $file, '<', "$filepath";
  my $fastaheader = <$file>;
  chomp $fastaheader;
  close $file;
  #>gi|556503834|ref|NC_000913.3| Escherichia coli str. K-12 substr. MG1655
  my @headerfields = split(/\|/, $fastaheader);
  my $accession = $headerfields[3];
  my $scientificName = $headerfields[4];
  my @ids;
  push(@ids,$accession);
  push(@ids,$scientificName);
  return @ids;
}

sub modify_fasta_header{
  my $inputFilepath = shift;
  my $outputFilepath = shift;
  my $header = shift;

  open INFILE, '<', "$inputFilepath";
  my @newfasta;
  while (<INFILE>) {
   push(@newfasta, $_);
  }
  close INFILE;
  #@newfasta  = @newfasta[ 1 .. $#newfasta ];
  shift @newfasta;
  unshift(@newfasta,">".$header."\n");

  open OUTFILE, '>', "$outputFilepath";
  foreach my $line (@newfasta) {
   print OUTFILE $line;
  }
  close OUTFILE;
  return 1;
}

1;
__END__

=head1 NAME

Bio::ViennaNGS::UCSC - Perl extension for easy UCSC Genome Browser
integration.

=head1 SYNOPSIS

  use Bio::ViennaNGS::UCSC;

=head1 DESCRIPTION

ViennaNGS::UCSC is a Perl extension for managing routine tasks with the
UCSC Genome Browser. It comes with a set of utilities that serve as
reference implementation of the routines implemented in the library. All
utilities are located in the 'scripts' folder.
The main functionality is provided by the make_assembly_hub function.

=head2 EXPORT

Routines: 
  make_assembly_hub

Variables:
  none

=head3 make_assembly_hub()

Build assembly hubs for the UCSC genome browser.
This function takes 4 parameters:
1. absolute path of input fasta file(e.g. /home/user/input.fa)
2. path to the ouput directory (e.g. /home/user/assemblyhubs/)
3. base URL where the output folder will be placed for upload to the UCSC genome browser (e.g. http://www.foo.com/folder/)
4. path for the log file (/home/user/logs/assemblyhubconstructionlog)

=head1 SEE ALSO

perldoc ViennaNGS
perldoc ViennaNGS::AnnoC

=head1 AUTHORS

Michael Thomas Wolfinger, E<lt>michael@wolfinger.euE<gt>
Florian Eggenhofer, E<lt>florian.eggenhofer@univie.ac.atE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.3 or,
at your option, any later version of Perl 5 you may have available.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.


=cut
