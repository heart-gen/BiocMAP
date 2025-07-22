module run_first_half {

    workflow run_first_half {

        log.info "Starting first_half pipeline..."

        // Read and preprocess manifest
        Channel.fromPath("${params.input}/samples.manifest")
            .splitText()
            .map { row -> get_fastq_names(row) }
            .flatten()
            .collect()
            .set { raw_fastqs }

        // Pull or set genome
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

        // Group reads by prefix
        if (params.sample == "single") {
            merged_inputs_flat
                .flatten()
                .map { file -> tuple(get_prefix(file), file) }
                .ifEmpty { error "Missing input fastq files after merging." }
                .set { fastqc_untrimmed_inputs; trimming_inputs }
        } else {
            merged_inputs_flat
                .flatten()
                .map { file -> tuple(get_prefix(file), file) }
                .groupTuple()
                .ifEmpty { error "Missing input fastq files after merging." }
                .set { fastqc_untrimmed_inputs; trimming_inputs }
        }

        FastQC_Untrimmed(fastqc_untrimmed_inputs)

        // Join with summaries for trimming
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

        Trimming(trimming_inputs)

        // Group trimming output
        if (params.sample == "single") {
            trimming_outputs
                .flatten()
                .map { file -> tuple(get_prefix(file), file) }
                .ifEmpty { error "Single-end trimming output channel is empty" }
                .set { ariocE_inputs1; ariocE_inputs2 }
        } else {
            trimming_outputs
                .flatten()
                .map { file -> tuple(get_prefix(file), file) }
                .groupTuple()
                .ifEmpty { error "Paired-end trimming output channel is empty" }
                .set { ariocE_inputs1; ariocE_inputs2 }
        }

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
}

