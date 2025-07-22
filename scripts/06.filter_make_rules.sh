#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=filter_make_rules
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 06-filter_make_rules.sh

echo "🧹 Filtering alignments and creating rules..."
nextflow run modules/FilterRules/make_rules.nf \
    --aligned "$WORK/aligned" \
    --output "$OUTPUT"
