#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=quality_trim
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 04-quality_trim.sh

echo "🔬 Running FastQC and trimming..."
nextflow run modules/QC/fastqc_trim.nf \
    --input "$WORK/preprocessed" \
    --trim_mode "$TRIM_MODE" \
    --sample "$SAMPLE" \
    --output "$WORK/trimmed"
