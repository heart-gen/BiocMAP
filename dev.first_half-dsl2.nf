// ----------------------------------------------------
//                 BiocMAP - First Half
//        Nextflow DSL2 Pipeline Entry Script
// ----------------------------------------------------

nextflow.enable.dsl=2

// -------------------------------------
//   Help message
// -------------------------------------
def helpMessage() {
    log.info """
    ================================================================================
        BiocMAP - First Module
    ================================================================================

    Usage:
        nextflow run first_half.nf [options]

    Typical use case:
        nextflow run first_half.nf --sample "paired" --reference "hg38" \\
                                   -profile jhpce

    Required flags:
        --sample          "single" or "paired", depending on your FASTQ reads
        --reference       "hg38", "hg19", or "mm10" — reference genome for alignment

    Optional flags:
        --annotation      Path to store annotation-related files (default: ./ref)
        --custom_anno     Name of custom genome (if using pre-downloaded FASTA)
        --input           Path to directory containing samples.manifest (default: ./test)
        --output          Output directory for pipeline results (default: ./out)
        --trim_mode       Trimming mode: "skip", "adaptive" [default], or "force"
        --all_alignments  Include disconcordant/unmapped alignments in output
    """.stripIndent()
}

// -------------------------------------
//   Parse & validate command-line input
// -------------------------------------

// Print help if --help is used
if (params.help) {
    helpMessage()
    exit 0
}

// Set defaults
params.sample          = params.sample ?: ""
params.reference       = params.reference ?: ""
params.annotation      = params.annotation ?: "${workflow.projectDir}/ref"
params.custom_anno     = params.custom_anno ?: ""
params.output          = params.output ?: "${workflow.projectDir}/out"
params.input           = params.input ?: (
                            params.reference == "mm10"
                            ? "${workflow.projectDir}/test/mouse/${params.sample}"
                            : "${workflow.projectDir}/test/human/${params.sample}"
                        )
params.trim_mode       = params.trim_mode ?: "adaptive"
params.all_alignments  = params.all_alignments ?: false
params.work            = params.work ?: "${workflow.projectDir}/work"
params.use_bme         = params.use_bme ?: false
params.with_lambda     = params.with_lambda ?: false

// Validate required parameters
if (!(params.sample in ["single", "paired"])) {
    error "❌ --sample must be specified as either 'single' or 'paired'. Use --help for more information."
}

if (!params.reference) {
    error "❌ --reference must be specified (e.g. 'hg38', 'hg19', or 'mm10'). Use --help for more information."
}

log.info "Parameters initialized"
log.info "  Sample type:     ${params.sample}"
log.info "  Reference:       ${params.reference}"
log.info "  Input directory: ${params.input}"
log.info "  Output directory:${params.output}"
log.info "  Annotation dir:  ${params.annotation}"
log.info "  Trimming mode:   ${params.trim_mode}"

workflow run_first_half {

    log.info "Parameters initialized"

    // Emit manifest file and extract fastq file list
    Channel.fromPath("${params.input}/samples.manifest")
        .splitText()
        .map { row -> get_fastq_names(row) }
        .flatten()
        .collect()
        .set { raw_fastqs }

    // Reference genome setup
    if (params.custom_anno == "") {
        pull_reference()
    } else {
        Channel.fromPath("${params.annotation}/*.fa")
            .ifEmpty { error "Cannot find FASTA in annotation directory (and --custom_anno was specified)" }
            .first()
            .set { raw_genome }
    }

    prepare_reference(raw_genome)
    encode_reference(split_fastas, encode_ref_gap_cfg, encode_ref_nongap_cfg)
    preprocess_inputs(raw_fastqs)

    // Organize fastqs into paired/single format
    Channel.empty().set { fastqc_untrimmed_inputs }
    Channel.empty().set { trimming_inputs }

    if (params.sample == "single") {
        merged_inputs_flat
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .set { fastqc_untrimmed_inputs; trimming_inputs }
    } else {
        merged_inputs_flat
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .groupTuple()
            .set { fastqc_untrimmed_inputs; trimming_inputs }
    }

    // FastQC step
    FastQC_Untrimmed(fastqc_untrimmed_inputs)

    // Join FastQC summaries and fastqs for trimming
    if (params.sample == "single") {
        fastq_summaries_untrimmed1
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .join(trimming_inputs)
            .set { trimming_inputs }
    } else {
        fastq_summaries_untrimmed1
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .groupTuple()
            .join(trimming_inputs)
            .set { trimming_inputs }
    }

    // Run trimming
    Trimming(trimming_inputs)

    // Organize trimming outputs
    if (params.sample == "single") {
        trimming_outputs
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .set { ariocE_inputs1; ariocE_inputs2 }
    } else {
        trimming_outputs
            .flatten()
            .map { file -> tuple(get_prefix(file), file) }
            .groupTuple()
            .set { ariocE_inputs1; ariocE_inputs2 }
    }

    // Arioc config writing and encode
    WriteAriocConfigs(ariocE_inputs1, arioc_manifest)

    encode_reads_cfgs
        .flatten()
        .map { file -> tuple(get_prefix(file), file) }
        .join(ariocE_inputs2)
        .set { ariocE_merged_inputs }

    EncodeReads(ariocE_merged_inputs)

    encoded_reads
        .mix(align_reads_cfgs)
        .flatten()
        .map { file -> tuple(get_prefix(file), file) }
        .groupTuple()
        .set { align_in }

    AlignReads(align_in, gap_ref_files, nongap_ref_files, encoded_ref_files)

    concordant_sams_out
        .flatten()
        .map { file -> tuple(get_prefix(file), file) }
        .set { concordant_sams_in }

    FilterAlignments(concordant_sams_in)

    fastq_summaries_untrimmed2
        .mix(fastq_summaries_trimmed)
        .collect()
        .set { fastq_summaries_all }

    MakeRules(fastq_summaries_all)
}

workflow {
    run_first_half()
} 
