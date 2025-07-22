#!/bin/bash

INPUT_DIR="/gpfs/projects/b1042/HEART-GeN-Lab/wgbs-reprocessing/batch-1/fastq/_m/fastq_output"
MANIFEST_FILE="/gpfs/projects/p32505/opt/BiocMAP/test/human/paired/samples.manifest"

if [[ -z "$INPUT_DIR" || -z "$MANIFEST_FILE" ]]; then
    echo "Usage: $0 <input_directory> <output_manifest_file>"
    exit 1
fi

> "$MANIFEST_FILE"

# Find all fastq(.gz) files and sort them
FASTQ_FILES=($(find "$INPUT_DIR" -type f \( -name "*.fastq" -o -name "*.fastq.gz" \) | sort))

for R1 in "${FASTQ_FILES[@]}"; do
    # Match files with _R1 in the name
    if [[ "$R1" =~ _R1.*\.fastq(\.gz)?$ ]]; then
        R2="${R1/_R1/_R2}"
        if [[ -f "$R2" ]]; then
            # Extract sample ID (everything before _R1)
            filename=$(basename "$R1")
            sample_id="${filename%%_R1*}"

            echo -e "$(realpath "$R1")\t0\t$(realpath "$R2")\t0\t$sample_id" >> "$MANIFEST_FILE"
        fi
    fi
done

echo "Manifest with sample IDs created: $MANIFEST_FILE"