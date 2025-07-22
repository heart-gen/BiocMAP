#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=reference
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 02-reference.sh

set -e

if [[ -z "$CUSTOM_ANNO" ]]; then
    echo "Pulling reference genome for $REFERENCE..."
    nextflow run modules/ReferenceSetup/pull_reference.nf --reference "$REFERENCE" --annotation "$ANNOTATION"
else
    echo "Using custom annotation: $CUSTOM_ANNO"
    fasta=$(ls "$ANNOTATION"/*.fa 2>/dev/null | head -n 1)
    if [[ ! -f "$fasta" ]]; then
        echo "Could not find FASTA file in $ANNOTATION"
        exit 1
    fi
    echo "Found FASTA: $fasta"
fi

# Continue with reference processing
nextflow run modules/ReferenceSetup/prepare_reference.nf --annotation "$ANNOTATION"
