#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=setup
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 01-setup.sh
# Sets default parameters and validates inputs

show_help() {
cat << EOF
================================================================================
    BiocMAP - First Module
================================================================================

Usage:
    ./01-setup.sh --sample paired --reference hg38 [other options]

Required:
    --sample          "single" or "paired"
    --reference       "hg38", "hg19", or "mm10"

Optional:
    --annotation      Path to annotation (default: ./ref)
    --custom_anno     Custom genome name
    --input           Sample dir (default: test dir based on reference/sample)
    --output          Output directory (default: ./out)
    --trim_mode       Trimming mode: skip, adaptive [default], or force
    --all_alignments  Include disconcordant/unmapped alignments
EOF
}

# Fixed values
SAMPLE="paired"
REFERENCE="hg38"

# Default values
ANNOTATION="./ref"
CUSTOM_ANNO=""
OUTPUT="./out"
TRIM_MODE="adaptive"
ALL_ALIGNMENTS=false
USE_BME=false
WITH_LAMBDA=false
WORK="./work"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --sample) SAMPLE="$2"; shift ;;
        --reference) REFERENCE="$2"; shift ;;
        --annotation) ANNOTATION="$2"; shift ;;
        --custom_anno) CUSTOM_ANNO="$2"; shift ;;
        --input) INPUT="$2"; shift ;;
        --output) OUTPUT="$2"; shift ;;
        --trim_mode) TRIM_MODE="$2"; shift ;;
        --all_alignments) ALL_ALIGNMENTS=true ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
    shift
done

# Validate
if [[ "$SAMPLE" != "single" && "$SAMPLE" != "paired" ]]; then
    echo "--sample must be 'single' or 'paired'"
    exit 1
fi

if [[ -z "$REFERENCE" ]]; then
    echo "--reference is required"
    exit 1
fi

# Set default input if not set
if [[ -z "$INPUT" ]]; then
    INPUT="./test/$( [[ "$REFERENCE" == "mm10" ]] && echo "mouse" || echo "human" )/$SAMPLE"
fi

# Export all parameters for downstream use
export SAMPLE REFERENCE ANNOTATION CUSTOM_ANNO INPUT OUTPUT TRIM_MODE ALL_ALIGNMENTS USE_BME WITH_LAMBDA WORK

echo "Setup complete"