#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=encode_align
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 05-encode_align.sh

echo "⚙️ Writing Arioc configs and encoding reads..."
nextflow run modules/Alignment/encode_align.nf \
    --trimmed "$WORK/trimmed" \
    --annotation "$ANNOTATION" \
    --sample "$SAMPLE" \
    --output "$WORK/aligned"
