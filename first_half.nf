#!/usr/bin/env nextflow
/*
vim: syntax=groovy
-*- mode: groovy;-*-

--------------------------------------------------------------------
    BiocMAP- First Module
--------------------------------------------------------------------

input:  "samples.manifest", pointing to fastq or fastq.gz files
output: quality-filtered, deduplicated alignments in SAM format for each
        sample. Also, the file "rules.txt" required for running the second
        half/ module.

processes:
    A. Pre-processing on input FASTQ files- this involves decompressing any gzipped
       files, renaming file extensions or paired-end read suffices (if necessary),
       and merging files with the same sample ID
    
    1. FastQC on FASTQ files
    2. Trimming FASTQ files (by default based on adapter content FastQC metric)
    3. Alignment with Arioc
    4. Filter to high quality, unique alignments
*/

def helpMessage() {
    log.info"""
    ================================================================================
        BiocMAP- First Module
    ================================================================================
    
    Usage:
        nextflow first_half.nf [options]
    
    Typical use case:
        nextflow first_half.nf --sample "paired" --reference "hg38" \\
                               -profile jhpce
        
    Required flags:
        --sample:      "single" or "paired", depending on your FASTQ reads
        --reference:   "hg38", "hg19", or "mm10". The reference genome to be
                       used for alignment and methylation extraction
    
    Optional flags:
        --annotation [path]: the path to the directory to store annotation-
                          related files
        --custom_anno [name]: use the FASTA present in the annotation
                          directory, and associate it with a name for future
                          runs
        --input [path]:   the path to the directory containing the 
                          samples.manifest. Defaults to "./test"
        --output [path]:  the directory into which to place pipeline results 
                          and outputs. Defaults to "./out"
        --trim_mode [mode]: determines the conditions under which trimming occurs:
                          "skip": do not perform trimming on samples
                          "adaptive": [default] perform trimming on samples
                              that have failed the FastQC "Adapter content" 
                              metric
                          "force": perform trimming on all samples
        --all_alignments: include this flag to signal Arioc to also write
                          outputs for discondant, rejected, and unmapped reads.
                          Sam files for each outcome are kept as pipeline
                          outputs. By default, only concordant reads are used
                          for later processing (methylation extraction and
                          beyond)
    """.stripIndent()
}


// -------------------------------------
//   Define default values for params
// -------------------------------------

params.all_alignments = false
params.annotation = "${workflow.projectDir}/ref"
params.custom_anno = ""
params.force_trim = false
params.output = "${workflow.projectDir}/out"
params.reference = ""
params.sample = ""
params.trim_mode = "adaptive"
params.use_bme = false
params.with_lambda = false
params.work = "${workflow.projectDir}/work"

if (params.reference == "mm10") {
    params.input = "${workflow.projectDir}/test/mouse/${params.sample}"
} else {
    params.input = "${workflow.projectDir}/test/human/${params.sample}"
}

// Ensure we have absolute paths without "." or "..". See
// https://github.com/LieberInstitute/BiocMAP/issues/31
params.input_clean = java.nio.file.Paths.get(params.input).toAbsolutePath().normalize().toString()
params.output_clean = java.nio.file.Paths.get(params.output).toAbsolutePath().normalize().toString()

// -------------------------------------
//   Validate Inputs
// -------------------------------------

if (params.sample != "single" && params.sample != "paired") {
    exit 1, "Sample type not provided or invalid. Valid options for --sample are 'single' or 'paired'."
}

if (params.reference != "hg19" && params.reference != "hg38" && params.reference != "mm10") {
    exit 1, "Reference not provided or invalid. Valid options for --reference are 'hg19', 'hg38', or 'mm10'."
}

// Trim mode
if (params.trim_mode != "skip" && params.trim_mode != "adaptive" && params.trim_mode != "force") {
    exit 1, "'--trim_mode' accepts one of three possible arguments: 'skip', 'adaptive', or 'force'."
}

// ------------------------------------------------------------
//   Construct convenience variables (dependent on reference)
// ------------------------------------------------------------

if (params.custom_anno != "") {
    params.anno_version = "custom"
    params.anno_suffix = params.custom_anno + "_custom_build"
} else if (params.reference == "hg38") {
    params.anno_version = params.gencode_version_human
    params.anno_suffix = params.reference + '_gencode_v' + params.gencode_version_human + '_' + params.anno_build
    params.ref_fasta_link = "ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${params.gencode_version_human}/GRCh38.primary_assembly.genome.fa.gz"
} else if (params.reference == "hg19") {
    params.anno_version = params.gencode_version_human
    params.anno_suffix = params.reference + '_gencode_v' + params.gencode_version_human + 'lift37_' + params.anno_build
    params.ref_fasta_link = "ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${params.gencode_version_human}/GRCh37_mapping/GRCh37.primary_assembly.genome.fa.gz"
} else {  // mm10
    params.anno_version = params.gencode_version_mouse
    params.anno_suffix = params.reference + '_gencode_' + params.gencode_version_mouse + '_' + params.anno_build
    params.ref_fasta_link = "ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_mouse/release_${params.gencode_version_mouse}/GRCm38.primary_assembly.genome.fa.gz"
}


// ------------------------------------------------------------
//   Utilities for retrieving info from filenames
// ------------------------------------------------------------

def replace_listed(x, pattern_list, replacement) {
    for (pattern in pattern_list) {
        x = x.replaceAll(pattern, replacement)
    }
    return x
}

def get_prefix(f) {
    //  Remove these regardless of position in the string (note blackListAny is a regular expression)
    blackListAny = [~/(|_[12])_(un|)trimmed_summary/, ~/_success_token/, ~/_(trimmed|untrimmed)/, ~/_(reverse|forward)/, ~/_(paired|unpaired)/, ~/%(a21|raw|sqm|sqq)/, ~/CH[GH]_*O[BT]_|CpG_*O[BT]_/, ~/|_bedgraph_merged/]
    
    //  Replace these with a dot
    blackListDot = [~/(_[12]|_R[12])\./, ~/_(encode|align)_reads\./, ~/\.(c|cfu)/, ~/\.txt/, ~/\.gz/, ~/\.sorted/, ~/_val/]

    f = replace_listed(f.name.toString(), blackListAny, "")
    f = replace_listed(f, blackListDot, ".")
    
    return f.tokenize('.')[0]
}

def get_chromosome_name(f) {
    f.name.toString()
        .tokenize('.')[1]
        .replaceAll("chrchr", "chr")
}

def get_file_ext(f) {
    if (f.name.toString().tokenize(".")[-1] == "gz") {
        return('.fastq.gz')
    } else {
        return('.fastq')
    }
}

def get_context(f) {
    f.name.toString()
        .tokenize('.')[0][-3..-1]
}

//  Given a "row" of the 'samples.manifest' file as a string, return the FASTQ
//  files
def get_fastq_names(row) {
    if (params.sample == "single") {
        return(file(row.tokenize('\t')[0]))
    } else {
        return(tuple(file(row.tokenize('\t')[0]), file(row.tokenize('\t')[2])))
    }
}


// ------------------------------------------------------------
//  Print all parameters to log
// ------------------------------------------------------------


// This gets the SHA commit ID of the repository where BiocMAP is installed.
// This associates the pipeline run with a precise "version" of BiocMAP. Note
// that nextflow provides the "workflow.commitId" variable with this intended
// function- during testing this variable appears to be null.
params.commitId = "git --git-dir=${workflow.projectDir}/.git rev-parse HEAD".execute().text.trim()

def summary_main = [:]
summary_main['BiocMAP version'] = params.commitId
summary_main['Config profile'] = workflow.profile
summary_main['All alignments'] = params.all_alignments
summary_main['Annotation dir'] = params.annotation
summary_main['Annotation release'] = params.anno_version
summary_main['Annotation build'] = params.anno_build
summary_main['Custom anno label'] = params.custom_anno
summary_main['Input dir'] = params.input_clean
summary_main['Output dir'] = params.output_clean
summary_main['Reference'] = params.reference
summary_main['Sample']	= params.sample
summary_main['Trim mode'] = params.trim_mode
summary_main['Working dir'] = workflow.workDir
summary_main['Current user']		= "$USER"

def summary_args = [:]
summary_args['Arioc GPU batch size'] = params.batch_size
summary_args['Arioc gapped seed'] = params.gapped_seed
summary_args['Arioc non-gapped seed'] = params.nongapped_seed
summary_args['Arioc gapped args'] = params.gapped_args
summary_args['Arioc non-gapped args'] = params.nongapped_args
summary_args['Arioc X args'] = params.x_args
summary_args['Arioc max GPUs'] = params.max_gpus
summary_args['Manually set GPU'] = params.manually_set_gpu
summary_args['GPU usage cutoff'] = params.gpu_perc_usage_cutoff

log.info "================================================================================"
log.info "    BiocMAP- First Module"
log.info "================================================================================"
log.info "---- Main options:"
log.info summary_main.collect { k,v -> "${k.padRight(20)}: $v" }.join("\n")
log.info "---- Software arguments:"
log.info summary_args.collect { k,v -> "${k.padRight(25)}: $v" }.join("\n")
log.info "================================================================================"

// ######################################################
//    Pre-processing steps 
// ######################################################

if (params.custom_anno == "") {
    // Pull the reference fasta for the given reference; subset to "main" sequences
    // if necessary
    process PullReference {
        storeDir "${params.annotation}/${params.anno_suffix}"

        input:
            file split_fasta_script from file("${workflow.projectDir}/scripts/split_fasta.sh")
        output:
            file "$out_fasta" into raw_genome

        shell:
            //  Name of the primary assembly fasta after being downloaded and unzipped
            baseName = file("${params.ref_fasta_link}").getName() - ".gz"

            //  Name the pipeline will use for the primary and main assembly fastas, respectively
            primaryName = "assembly_${params.anno_suffix}.fa".replaceAll("main", "primary")
            mainName = "assembly_${params.anno_suffix}.fa".replaceAll("primary", "main")

            //  Name of fasta to use for this pipeline execution instance
            out_fasta = "assembly_${params.anno_suffix}.fa"
            '''
            mkdir -p !{params.annotation}/!{params.anno_suffix}
            
            #  Pull fasta from GENCODE
            wget !{params.ref_fasta_link}
            gunzip !{baseName}.gz
            mv !{baseName} !{primaryName} # rename for consistency with pipeline naming conventions
            
            #######################################################################
            #  Create the "main" fasta of canonical seqs only
            #######################################################################
            
            if [ !{params.anno_build} == "main" ]; then
                #  Determine how many chromosomes/seqs to keep
                if [ !{params.reference} == "mm10" ]; then
                    num_chrs=22
                else
                    num_chrs=25
                fi
                #  Find the line of the header for the first extra contig (to not
                #  include in the "main" annotation fasta
                first_bad_line=$(grep -n ">" !{primaryName} | cut -d : -f 1 | paste -s | cut -f $(($num_chrs + 1)))
                
                #  Make a new file out of all the lines up and not including that
                sed -n "1,$(($first_bad_line - 1))p;${first_bad_line}q" !{primaryName} > !{mainName}
            fi
            '''
    }
} else {
    Channel.fromPath("${params.annotation}/*.fa")
        .ifEmpty{ error "Cannot find FASTA in annotation directory (and --custom_anno was specified)" }
        .first()  // This proves to nextflow that the channel will always hold one value/file
        .into{ raw_genome }
}

//  Split the fasta into individual files (1 per canonical sequence) and write
//  the configs for encoding the reference with AriocE
process PrepareReference {
    storeDir "${params.annotation}/${params.anno_suffix}"
    
    input:
        file split_fasta_script from file("${workflow.projectDir}/scripts/split_fasta.sh")
        file encode_ref_script from file("${workflow.projectDir}/scripts/write_configs_encode_ref.R")
        file raw_genome
    
    output:
        file "chr_names_${params.anno_suffix}"
        file "encode_ref_${params.gapped_seed}.cfg" into encode_ref_gap_cfg
        file "encode_ref_${params.nongapped_seed}.cfg" into encode_ref_nongap_cfg
        file "prepare_ref_first_${params.gapped_seed}_${params.nongapped_seed}.log"
        file "*.fa" into split_fastas
        
    shell:
        if (params.custom_anno != "") {
            genome_dirname = params.custom_anno
        } else {
            genome_dirname = params.anno_build
        }
        '''
        #  Make a file containing a list of seqnames
        grep ">" !{raw_genome} | cut -d " " -f 1 | cut -d ">" -f 2 > chr_names_!{params.anno_suffix}
        
        #  Split by sequence, to prepare for encoding reference with Arioc
        bash !{split_fasta_script} !{raw_genome}
        
        #  Write the Arioc configs for encoding the reference
        Rscript !{encode_ref_script} \
            -r !{params.reference} \
            -g !{params.gapped_seed} \
            -n !{params.nongapped_seed}
        
        #  Keep a log of what happened so far
        cp .command.log prepare_ref_first_!{params.gapped_seed}_!{params.nongapped_seed}.log
        '''
}


// Arioc requires an encoded reference sequence. This process builds that within the repo,
// if the encoded sequence hasn't been built before.
process EncodeReference {
    storeDir "${params.annotation}/${params.anno_suffix}"
    
    input:
        file encode_ref_gap_cfg
        file encode_ref_nongap_cfg
        file split_fastas
        
    output:
        file "${params.gapped_seed}/*.{sbf,cfg}" into gap_ref_files
        file "${params.nongapped_seed}/*.{sbf,cfg}" into nongap_ref_files
        file "*.sbf" into encoded_ref_files
        
    shell:
        '''
        #  Update the configs with this process' working directory
        sed -i "s|\\[future_work_dir\\]|$PWD|" !{encode_ref_gap_cfg}
        sed -i "s|\\[future_work_dir\\]|$PWD|" !{encode_ref_nongap_cfg}
        
        #  Encode gapped and nongapped seeds sequentially (later parallelize)
        AriocE !{encode_ref_gap_cfg}
        AriocE !{encode_ref_nongap_cfg}
        
        #  Rename files to allow nextflow to properly handle them ("$"
        #  characters otherwise sometimes begin the parsing of a bash variable)
        for filename in $(ls *\$*.sbf); do
            mv $filename $(echo $filename | sed 's/\\\$/%/')
        done
        '''
}

// Extract FASTQ file paths from the manifest and place in a channel to pass to
// PreprocessInputs
Channel
    .fromPath("${params.input_clean}/samples.manifest")
    .splitText()
    .map{ row -> get_fastq_names(row) }
    .flatten()
    .collect()
    .set{ raw_fastqs }

process PreprocessInputs {

    publishDir "${params.output_clean}/preprocessing", mode:'copy', pattern:'*.log'

    input:
        file original_manifest from file("${params.input_clean}/samples.manifest")
        file preprocess_script from file("${workflow.projectDir}/scripts/preprocess_inputs_first.R")
        file raw_fastqs
        
    output:
        file "*.f*q*" into merged_inputs_flat includeInputs true
        file "arioc_samples.manifest" into arioc_manifest
        file "preprocess_inputs_first_half.log"

    shell:
        '''
        Rscript !{preprocess_script}
        
        cp .command.log preprocess_inputs_first_half.log
        '''
}


//  Group both reads together for each sample, if paired-end, and assign each sample a prefix
if (params.sample == "single") {
    merged_inputs_flat
        .flatten()
        .map{file -> tuple(get_prefix(file), file) }
        .ifEmpty{ error "Input fastq files (after any merging) are missing from the channel"}
        .into{ fastqc_untrimmed_inputs; trimming_inputs }
} else {
    merged_inputs_flat
        .flatten()
        .map{file -> tuple(get_prefix(file), file) }
        .groupTuple()
        .ifEmpty{ error "Input fastq files (after any merging) are missing from the channel"}
        .into{ fastqc_untrimmed_inputs; trimming_inputs }
}

// ######################################################
//    Begin pipeline
// ######################################################


//  -----------------------------------------
//   Step 1: Run FastQC on each sample
//  -----------------------------------------

process FastQC_Untrimmed {
    tag "$prefix"
    publishDir "${params.output_clean}/FastQC/Untrimmed", mode:'copy', pattern:"${prefix}*_fastqc"

    input:
        set val(prefix), file(fq_file) from fastqc_untrimmed_inputs 

    output:
        file "${prefix}*_fastqc"
        file "*_summary.txt" into fastq_summaries_untrimmed1, fastq_summaries_untrimmed2

    shell:
        if (params.sample == "single") {
            copy_command = "cp ${prefix}_fastqc/summary.txt ${prefix}_untrimmed_summary.txt"
        } else {
            copy_command = "cp ${prefix}_1_fastqc/summary.txt ${prefix}_1_untrimmed_summary.txt && cp ${prefix}_2_fastqc/summary.txt ${prefix}_2_untrimmed_summary.txt"
        }
        '''
        fastqc -t !{task.cpus} *.f*q* --extract
        
        !{copy_command}
        '''
}

//  Combine FASTQ files and FastQC result summaries for each sample, to form the input channel for Trimming
if (params.sample == "single") {

    fastq_summaries_untrimmed1
        .flatten()
        .map{ file -> tuple(get_prefix(file), file) }
        .join(trimming_inputs)
        .ifEmpty{ error "All files (fastQC summaries on untrimmed inputs, and the FASTQs themselves) missing from input to trimming channel." }
        .set{ trimming_inputs }
        
} else { // paired

    fastq_summaries_untrimmed1
        .flatten()
        .map{ file -> tuple(get_prefix(file), file) }
        .groupTuple()
        .join(trimming_inputs)
        .ifEmpty{ error "All files (fastQC summaries on untrimmed inputs, and the FASTQs themselves) missing from input to trimming channel." }
        .set{ trimming_inputs }
}    


//  -----------------------------------------------------------------------
//   Step 2: Trim FASTQ files if required (or requested via --force_trim)
//  -----------------------------------------------------------------------

process Trimming {

    tag "Prefix: $fq_prefix"
    publishDir "${params.output_clean}/Trimming", mode:'copy', pattern:"${fq_prefix}_[!u]*{.fq,_trimmed.log}"
    publishDir "${params.output_clean}/FastQC/Trimmed", mode:'copy', pattern:"${fq_prefix}*_fastqc"

    input:
        set val(fq_prefix), file(fq_summary), file(fq_file) from trimming_inputs

    output:
        file "${fq_prefix}*_fastqc" optional true
        file "${fq_prefix}_*_trimmed.log"
        file "${fq_prefix}*.fq" into trimming_outputs
        file "${fq_prefix}*_trimmed_summary.txt" optional true into fastq_summaries_trimmed

    shell:
        file_ext = get_file_ext(fq_file[0])
        trim_args = "--illumina --fastqc --fastqc_args '--extract' --dont_gzip --basename ${fq_prefix}"
        if (params.sample == "paired") {
            trim_args = trim_args + " --paired"
        }
        '''
        #  Determine whether to trim the FASTQ file(s). This is ultimately
        #  controlled by the '--trim_mode' command flag.
        if [ "!{params.trim_mode}" == "force" ]; then
            do_trim=true
        elif [ "!{params.trim_mode}" == "skip" ]; then
            do_trim=false
        elif [ "!{params.sample}" == "single" ]; then
            #  Then '--trim_mode "adaptive"' was selected, and data is single-end
            #  (was fq_summary)
            if [ $(grep "Adapter Content" *summary.txt | cut -f 1)  == "FAIL" ]; then
                do_trim=true
            else
                do_trim=false
            fi
        else
            #  Then '--trim_mode "adaptive"' was selected, and data is paired-end
            result1=$(grep "Adapter Content" !{fq_prefix}_1_summary.txt | cut -c1-4)
            result2=$(grep "Adapter Content" !{fq_prefix}_2_summary.txt | cut -c1-4)
            if [ $result1 == "FAIL" ] || [ $result2 == "FAIL" ]; then
                do_trim=true
            else
                do_trim=false
            fi
        fi
        
        #  Run trimming if required
        if [ "$do_trim" == true ]; then
            trim_galore !{trim_args} *.f*q*
            
            if [ "!{params.sample}" == "paired" ]; then
                mv !{fq_prefix}_val_1_fastqc !{fq_prefix}_1_fastqc
                mv !{fq_prefix}_val_2_fastqc !{fq_prefix}_2_fastqc
                
                cp !{fq_prefix}_1_fastqc/summary.txt !{fq_prefix}_1_trimmed_summary.txt
                cp !{fq_prefix}_2_fastqc/summary.txt !{fq_prefix}_2_trimmed_summary.txt
            else
                cp !{fq_prefix}_trimmed_fastqc/summary.txt !{fq_prefix}_trimmed_summary.txt
            fi
            
            cp .command.log !{fq_prefix}_was_trimmed.log
        else
            #  Otherwise rename files (for compatibility downnstream, and to signal to
            #  nextflow to output these files) and decompress as necessary
            if [ !{file_ext} == '.fastq.gz' ]; then
                if [ "!{params.sample}" == "single" ]; then
                    gunzip -c !{fq_prefix}!{file_ext} > !{fq_prefix}_untrimmed.fq
                else
                    gunzip -c !{fq_prefix}_1!{file_ext} > !{fq_prefix}_untrimmed_val_1.fq
                    gunzip -c !{fq_prefix}_2!{file_ext} > !{fq_prefix}_untrimmed_val_2.fq
                fi
            else
                if [ "!{params.sample}" == "single" ]; then
                    mv !{fq_prefix}!{file_ext} !{fq_prefix}_untrimmed.fq
                else
                    mv !{fq_prefix}_1!{file_ext} !{fq_prefix}_untrimmed_1.fq
                    mv !{fq_prefix}_2!{file_ext} !{fq_prefix}_untrimmed_2.fq
                fi
            fi
            
            cp .command.log !{fq_prefix}_not_trimmed.log
        fi      
        '''
}

//  Pair trimming output FASTQs into a channel, grouped by sample name ("prefix")
if (params.sample == "single") {

    trimming_outputs
        .flatten()
        .map{ file -> tuple(get_prefix(file), file) }
        .ifEmpty{ error "Single-end trimming output channel is empty" }
        .into{ ariocE_inputs1; ariocE_inputs2 }
} else {

    trimming_outputs
        .flatten()
        .map{ file -> tuple(get_prefix(file), file) }
        .groupTuple()
        .ifEmpty{ error "Paired-end trimming output channel is empty" }
        .into{ ariocE_inputs1; ariocE_inputs2 }
}


//  -------------------------------------------------------------------------
//   Step 4: Alignment with Arioc
//  -------------------------------------------------------------------------

//  This is done separately from the encode/ align steps, as writing the configs
//  uses R (possibly not available on a GPU node, where encoding/alignment is done)
process WriteAriocConfigs {

    publishDir "${params.output_clean}/Arioc/configs/",mode:'copy'
    tag "$fq_prefix"
    
    input:
        set val(fq_prefix), file(fq_file) from ariocE_inputs1
        file encode_reads_script from file("${workflow.projectDir}/scripts/write_config_encode_reads.R")
        file align_reads_script from file("${workflow.projectDir}/scripts/write_config_align.R")
        file arioc_manifest
        
    output:
        file "write_configs_${fq_prefix}.log"
        file "*_encode_reads.cfg" into encode_reads_cfgs
        file "*_align_reads.cfg" into align_reads_cfgs
        
    shell:
        if (params.sample == "paired") {
            exec_name = "AriocP"
        } else {
            exec_name = "AriocU"
        }
        
        //  Form strings containing lines to write in the Arioc configs, that
        //  are dependent on parameters from the first-half config
        nongapped_opts = '  <nongapped seed="' + params.nongapped_seed + \
                         '" ' + params.nongapped_args + '/>'
        gapped_opts = '  <gapped seed="' + params.gapped_seed + '" ' + \
                      params.gapped_args + '/>'
        x_opts = '  <X ' + params.x_args + '/>'
        '''
        Rscript !{encode_reads_script} \
            -p !{params.sample} \
            -x !{fq_prefix}
            
        Rscript !{align_reads_script} \
            -p !{params.sample} \
            -a !{params.all_alignments} \
            -f !{fq_prefix} \
            -b !{params.batch_size} \
            -m !{params.max_gpus} \
            -g \'!{gapped_opts}\' \
            -n \'!{nongapped_opts}\' \
            -x \'!{x_opts}\' \
            
        cp .command.log write_configs_!{fq_prefix}.log
        '''
}

//  Combine (possibly trimmed) FASTQ files into a channel with their associated
//  AriocE.cfg file
encode_reads_cfgs
    .flatten()
    .map{ file -> tuple(get_prefix(file), file) }
    .join( ariocE_inputs2 )
    .ifEmpty{ error "Input channel for AriocE is empty" }
    .set{ ariocE_merged_inputs }


//  FASTQs must be encoded with AriocE, before the alignment step
process EncodeReads {

    publishDir "${params.output_clean}/Arioc/logs/", mode:'copy', pattern:'*.log'
    tag "$fq_prefix"
    
    input:
        set val(fq_prefix), file(config), file(fq_file) from ariocE_merged_inputs
        
    output:
        file "${fq_prefix}*.{sbf,cfg}" into encoded_reads
        file "encode_${fq_prefix}.log"
        
    shell:
        '''
        #  Update the configs with this process' working directory
        sed -i "s|\\[future_work_dir\\]|$PWD|" !{fq_prefix}_encode_reads.cfg
        
        #  Encode reads
        AriocE !{fq_prefix}_encode_reads.cfg
        
        #  Rename files to allow nextflow to properly handle them ("$"
        #  characters otherwise sometimes begin the parsing of a bash variable)
        for filename in $(ls *\$*.sbf); do
            mv $filename $(echo $filename | sed 's/\\\$/%/')
        done
        
        cp .command.log encode_!{fq_prefix}.log
        '''
}

//  This channel includes encoded reads and their associated Arioc alignment config
encoded_reads
    .mix(align_reads_cfgs)
    .flatten()
    .map{ file -> tuple(get_prefix(file), file) }
    .groupTuple()
    .ifEmpty{ error "Encoded reads and/or alignment configs missing from input to 'AlignReads' process." }
    .set{ align_in }

process AlignReads {   
    
    publishDir "${params.output_clean}/Arioc/sams/", mode:'copy', pattern:'*.sam'
    publishDir "${params.output_clean}/Arioc/logs/", mode:'copy', pattern:'*.log'
    tag "$prefix"
    
    input:
        set val(prefix), file(cfg_and_encoded_reads) from align_in
        file gap_ref_files
        file nongap_ref_files
        file encoded_ref_files
        
    output:
        file "${prefix}.[dru].sam" optional true
        file "${prefix}.[cm].sam" into concordant_sams_out
        file "${prefix}_alignment.log" into arioc_reports_out
        
    shell:
        if (params.sample == "paired") {
            exec_name = "AriocP"
        } else {
            exec_name = "AriocU"
        }
        '''
        #  Rename files to their original names given by Arioc
        for filename in $(ls *%*.sbf); do
            mv $filename $(echo $filename | sed 's/%/$/')
        done
        
        #  Recreate the directory layout for Arioc reference files (as they
        #  were originally created)
        mkdir !{params.gapped_seed}
        for file in !{gap_ref_files}; do
            mv $file !{params.gapped_seed}/
        done
        
        mkdir !{params.nongapped_seed}
        for file in !{nongap_ref_files}; do
            mv $file !{params.nongapped_seed}/
        done
        
        #  Isolate encoded reads into their own directory, renaming any files
        #  with the "%" character to have the "$" character as originally named
        #  by Arioc
        mkdir encoded_reads
        for filename in $(ls !{prefix}*.{sbf,cfg} | grep -v "align_reads"); do
            mv $filename encoded_reads/$(echo $filename | sed 's/%/$/')
        done

        #  Modify the alignment config with the current working directory and
        #  appropriate GPU mask (after checking availability now)
        sed -i "s|\\[future_work_dir\\]|$PWD|" !{prefix}_align_reads.cfg
        
        if [[ !{params.manually_set_gpu} == true ]]; then
            avail_gpus=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | cut -d " " -f 1 | awk '$1 < !{params.gpu_perc_usage_cutoff} {print NR - 1}')
    
            if [[ -z $avail_gpus ]]; then
                echo "No GPUs are available."
                exit 1
            fi
            
            export CUDA_VISIBLE_DEVICES=$(echo "$avail_gpus" | paste -sd ",")
        fi
        
        #  Run alignment
        !{exec_name} !{prefix}_align_reads.cfg
        cp .command.log !{prefix}_alignment.log
        
        #  Rename sams to be [sampleName].[alignment_type].sam
        for sam in $(ls Arioc*.sam); do
            sam_type=$(echo $sam | cut -d "." -f 2)
            mv $sam !{prefix}.$sam_type.sam
        done
        '''
}

concordant_sams_out
    .flatten()
    .map{ file -> tuple(get_prefix(file), file) }
    .ifEmpty{ error "Concordant sams missing from input to 'FilterSam' process." }
    .set{ concordant_sams_in }
    

//  To be specific, this process takes the sam file of concordant reads from
//  Arioc, filters by mapping quality, and removes duplicate mappings.
process FilterAlignments {

    publishDir "${params.output_clean}/FilteredAlignments/logs/", mode:'copy', pattern:'*.log'
    publishDir "${params.output_clean}/FilteredAlignments/bams/", mode:'copy', pattern:'*.bam*'
    tag "$prefix"
    
    input:
        set val(prefix), file(sam_file) from concordant_sams_in
        
    output:
        file "${prefix}.[cm]fus.bam*"
        file "filter_alignments_${prefix}.log"
        
    shell:
        // Allocate 1 thread to 'samtools view' and to 'samblaster', with the
        // remaining used for 'samtools sort'
        if (task.cpus < 3) {
            sort_threads = 1
        } else {
            sort_threads = task.cpus - 2
        }
        
        // Appropriately name BAM files
        if (params.sample == "paired") {
            bam_type = "cfus"
        } else {
            bam_type = "mfus"
        }
        '''
        #  Quality-filter, deduplicate, and sort
        samtools view -q 5 -F 0x100 -h !{sam_file} \
            | samblaster -r \
            | samtools sort -@ !{sort_threads} -o !{prefix}.!{bam_type}.bam -
        
        #  Index BAM
        samtools index -@ !{task.cpus} !{prefix}.!{bam_type}.bam
        
        cp .command.log filter_alignments_!{prefix}.log
        '''
}

fastq_summaries_untrimmed2
    .mix(fastq_summaries_trimmed)
    .collect()
    .set{ fastq_summaries_all }
    
//  Generate a 'rules.txt' file automatically, for use as input to the second
//  module
process MakeRules {
    publishDir "${params.output_clean}", mode:'copy'
    
    input:
        file fastq_summaries_all
        
    output:
        file 'rules.txt'
        
    shell:
        // Appropriately name BAM files and directories containing FastQC logs
        if (params.sample == "paired") {
            bam_type = "cfus"
            fastqc_dir = "[id]_[12]_fastqc"
        } else {
            bam_type = "mfus"
            fastqc_dir = "[id]*_fastqc"
        }
        
        txt = "# Automatically generated input to the second module/half\n" + \
              "manifest = ${params.input_clean}/samples.manifest\n" + \
              "sam = ${params.output_clean}/FilteredAlignments/bams/[id].${bam_type}.bam*\n" + \
              "arioc_log = ${params.output_clean}/Arioc/logs/[id]_alignment.log\n" + \
              "trim_report = ${params.output_clean}/Trimming/[id]_was_trimmed.log"
        
        '''
        echo -e '!{txt}' > rules.txt
        
        #  Define 'fastqc_log_last' and possibly 'fastqc_log_first' key(s)
        #  depending on if any samples were trimmed (and thus have
        #  post-trimming FastQC reports)
        if [ $(ls -1 *_trimmed_summary.txt | wc -l) -gt 0 ]; then
            #  If there are as many trimmed as untrimmed reports, all samples
            #  were trimmed. Otherwise only some were
            if [ $(ls -1 *_trimmed_summary.txt | wc -l) -eq $(ls -1 *_untrimmed_summary.txt | wc -l) ]; then
                echo 'fastqc_log_last = !{params.output_clean}/FastQC/Trimmed/!{fastqc_dir}/summary.txt' >> rules.txt
            else
                echo 'fastqc_log_last = !{params.output_clean}/FastQC/Trimmed/!{fastqc_dir}/summary.txt' >> rules.txt
                echo 'fastqc_log_first = !{params.output_clean}/FastQC/Untrimmed/!{fastqc_dir}/summary.txt' >> rules.txt
            fi
        else
            echo 'fastqc_log_last = !{params.output_clean}/FastQC/Untrimmed/!{fastqc_dir}/summary.txt' >> rules.txt
        fi
        '''
}
