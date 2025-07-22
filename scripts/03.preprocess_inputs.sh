#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=preprocess_inputs
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email
#SBATCH --output=fastqc.%j.log

# 03-preprocess_inputs.sh

echo "📂 Reading manifest from $INPUT/samples.manifest"
nextflow run modules/InputPrep/preprocess_inputs.nf \
    --manifest "$INPUT/samples.manifest" \
    --sample "$SAMPLE" \
    --output "$WORK/preprocessed"
