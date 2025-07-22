#!/bin/bash
#SBATCH --account=b1042
#SBATCH --partition=genomics-gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --time=2:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=BiocMAP
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=elisajohnson2027@u.northwestern.edu # Replace with your email

#  Load modules to work on Quest with DSL1

module purge
module load git/2.37.2
module load java/jdk-17.0.2+8
module load singularity/3.8.1
module list

#  After running 'install_software.sh', this should point to the directory
#  where this repo was cloned, and not say "$PWD"
ORIG_DIR=/gpfs/projects/p32505/opt/BiocMAP

export _JAVA_OPTIONS="-Xms8g -Xmx10g"

NXF_VER=22.10.8 $ORIG_DIR/Software/bin/nextflow run \
                $ORIG_DIR/first_half.nf \
                --annotation "$ORIG_DIR/ref" \
                --sample "paired" \
                --reference "hg38" \
                -profile first_half_slurm \
                --input "${ORIG_DIR}/test/human/paired"
