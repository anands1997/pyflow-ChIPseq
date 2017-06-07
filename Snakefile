shell.prefix("set -eo pipefail; echo BEGIN at $(date); ")
shell.suffix("; exitstat=$?; echo END at $(date); echo exit status was $exitstat; exit $exitstat")

configfile: "config.yaml"

localrules: all
# localrules will let the rule run locally rather than submitting to cluster
# computing nodes, this is for very small jobs

# load cluster config file
CLUSTER = json.load(open(config['CLUSTER_JSON']))
FILES = json.load(open(config['SAMPLES_JSON']))

import csv
import os

SAMPLES = sorted(FILES.keys())

## will be named as sample_IP  sample_Input
MARK_SAMPLES = []
for sample in SAMPLES:
    for mark in FILES[sample].keys():
        MARK_SAMPLES.append(sample + "_" + mark) 


CONTROLS = [sample for sample in MARK_SAMPLES if '_Input' in sample]
CASES = [sample for sample in MARK_SAMPLES if '_Input'  not in sample]


## multiple samples may use the same control input files
CONTROLS_UNIQUE = list(set(CONTROLS))


## list BAM files
CONTROL_BAM = expand("03aln/{sample}.sorted.bam", sample=CONTROLS_UNIQUE)
CASE_BAM = expand("03aln/{sample}.sorted.bam", sample=CASES)


## create target for peak-calling: will call the rule call_peaks in order to generate bed files
## note: the "zip" function allow the correct pairing of the BAM files
ALL_PEAKS = expand("08peak_macs1/{case}_vs_{control}_macs1_peaks.bed", zip, case=CASES, control=CONTROLS)
ALL_PEAKS.extend(expand("08peak_macs1/{case}_vs_{control}_macs1_nomodel_peaks.bed", zip, case=CASES, control=CONTROLS))
ALL_PEAKS.extend(expand("09peak_macs2/{case}_vs_{control}_macs2_peaks.xls", zip, case=CASES, control=CONTROLS))


ALL_inputSubtract_BIGWIG = expand("06bigwig_inputSubtract/{case}_subtract_{control}.bw", zip, case=CASES, control=CONTROLS)

ALL_SUPER = expand("11superEnhancer/{case}_vs_{control}-super/", zip, case=CASES, control=CONTROLS)


ALL_SAMPLES = CASES + CONTROLS_UNIQUE
ALL_BAM     = CONTROL_BAM + CASE_BAM
ALL_DOWNSAMPLE_BAM = expand("04aln_downsample/{sample}-downsample.sorted.bam", sample = ALL_SAMPLES)
ALL_FASTQ   = expand("01seq/{sample}.fastq", sample = ALL_SAMPLES)
ALL_FASTQC  = expand("02fqc/{sample}_fastqc.zip", sample = ALL_SAMPLES)
ALL_INDEX = expand("03aln/{sample}.sorted.bam.bai", sample = ALL_SAMPLES)
ALL_DOWNSAMPLE_INDEX = expand("04aln_downsample/{sample}-downsample.sorted.bam.bai", sample = ALL_SAMPLES)
ALL_FLAGSTAT = expand("03aln/{sample}.sorted.bam.flagstat", sample = ALL_SAMPLES)
ALL_PHATOM = expand("05phantompeakqual/{sample}_phantom.txt", sample = ALL_SAMPLES)
ALL_BIGWIG = expand("07bigwig/{sample}.bw", sample = ALL_SAMPLES)
ALL_QC = ["10multiQC/multiQC_log.html"]


localrules: all
rule all:
    input: ALL_FASTQC + ALL_BAM + ALL_DOWNSAMPLE_BAM + ALL_INDEX + ALL_DOWNSAMPLE_INDEX + ALL_PHATOM + ALL_PEAKS + ALL_BIGWIG + ALL_inputSubtract_BIGWIG + ALL_FASTQ + ALL_FLAGSTAT + ALL_QC + ALL_SUPER


## get a list of fastq.gz files for the same mark, same sample
def get_fastq(wildcards):
    sample = "_".join(wildcards.sample.split("_")[0:-1])
    mark = wildcards.sample.split("_")[-1]
    return FILES[sample][mark]

## now only for single-end ChIPseq, 
rule merge_fastqs:
    input: get_fastq      
    output: "01seq/{sample}.fastq"
    log: "00log/{sample}_unzip"
    threads: CLUSTER["merge_fastqs"]["cpu"]
    params: jobname = "{sample}"
    message: "merging fastqs gunzip -c {input} > {output}"
    shell: "gunzip -c {input} > {output} 2> {log}"

rule fastqc:
    input:  "01seq/{sample}.fastq"
    output: "02fqc/{sample}_fastqc.zip", "02fqc/{sample}_fastqc.html"
    log:    "00log/{sample}_fastqc"
    threads: CLUSTER["fastqc"]["cpu"]
    params : jobname = "{sample}"
    message: "fastqc {input}: {threads}"
    shell:
        """
        module load fastqc
        fastqc -o 02fqc -f fastq --noextract {input} 2> {log}
        """

# get the duplicates marked sorted bam, remove unmapped reads by samtools view -F 4 and dupliated reads by samblaster -r
# samblaster should run before samtools sort
rule align:
    input:  "01seq/{sample}.fastq"
    output: "03aln/{sample}.sorted.bam", "00log/{sample}.align"
    threads: CLUSTER["align"]["cpu"]
    params: 
            bowtie = "--chunkmbs 320 -m 1 --best -p 5 ",
            jobname = "{sample}"
    message: "aligning {input}: {threads} threads"
    log: 
        bowtie = "00log/{sample}.align",
        markdup = "00log/{sample}.markdup"
    shell:
        """
        bowtie {params.bowtie} {config[idx_bt1]} -q {input} -S 2> {log.bowtie} \
        | samblaster --removeDups \
	| samtools view -Sb -F 4 - \
	| samtools sort -m 2G -@ 5 -T {output[0]}.tmp -o {output[0]} 2> {log.markdup}
        """

rule index_bam:
    input:  "03aln/{sample}.sorted.bam"
    output: "03aln/{sample}.sorted.bam.bai"
    log:    "00log/{sample}.index_bam"
    threads: 1
    params: jobname = "{sample}"
    message: "index_bam {input}: {threads} threads"
    shell:
        """
        samtools index {input} 2> {log}
        """

# check number of reads mapped by samtools flagstat, the output will be used for downsampling
rule flagstat_bam:
    input:  "03aln/{sample}.sorted.bam"
    output: "03aln/{sample}.sorted.bam.flagstat"
    log:    "00log/{sample}.flagstat_bam"
    threads: 1
    params: jobname = "{sample}"
    message: "flagstat_bam {input}: {threads} threads"
    shell:
        """
        samtools flagstat {input} > {output} 2> {log}
        """

rule phantom_peak_qual:
    input: "03aln/{sample}.sorted.bam", "03aln/{sample}.sorted.bam.bai"
    output: "05phantompeakqual/{sample}_phantom.txt"
    log: "00log/{sample}_phantompeakqual.log"
    threads: 4
    params: jobname = "{sample}"
    message: "phantompeakqual for {input}"
    shell:
        """
	source activate root
        Rscript  /scratch/genomic_med/apps/phantompeak/phantompeakqualtools/run_spp_nodups.R -c={input[0]} -savp -rf -p=4 -odir=05phantompeakqual  -out={output} -tmpdir=05phantompeakqual 2> {log}

        """

rule down_sample:
    input: "03aln/{sample}.sorted.bam", "03aln/{sample}.sorted.bam.bai", "03aln/{sample}.sorted.bam.flagstat"
    output: "04aln_downsample/{sample}-downsample.sorted.bam", "04aln_downsample/{sample}-downsample.sorted.bam.bai"
    log: "00log/{sample}_downsample.log"
    threads: 5
    params: jobname = "{sample}"
    message: "downsampling for {input}"
    run:
        import re
        import subprocess
        with open (input[2], "r") as f:
            # fifth line contains the number of mapped reads
            line = f.readlines()[4]
            match_number = re.match(r'(\d.+) \+.+', line)
            total_reads = int(match_number.group(1))
                   
        target_reads = config["target_reads"] # 15million reads  by default, set up in the config.yaml file
        if total_reads > target_reads:
            down_rate = target_reads/total_reads
        else:
            down_rate = 1

        shell("sambamba view -f bam -t 5 --subsampling-seed=3 -s {rate} {inbam} | samtools sort -m 2G -@ 5 -T {outbam}.tmp > {outbam} 2> {log}".format(rate = down_rate, inbam = input[0], outbam = output[0], log = log))
        
        shell("samtools index {outbam}".format(outbam = output[0]))

rule make_inputSubtract_bigwigs:
    input : "04aln_downsample/{control}-downsample.sorted.bam", "04aln_downsample/{case}-downsample.sorted.bam", "04aln_downsample/{control}-downsample.sorted.bam.bai", "04aln_downsample/{case}-downsample.sorted.bam.bai"
    output:  "06bigwig_inputSubtract/{case}_subtract_{control}.bw"
    log: "00log/{case}_inputSubtract.makebw"
    threads: 5
    params: jobname = "{case}"
    message: "making input subtracted bigwig for {input}"
    shell:
        """
	source activate root
        bamCompare --bamfile1 {input[1]} --bamfile2 {input[0]} --normalizeUsingRPKM --ratio subtract --binSize 30 --smoothLength 300 -p 5  --extendReads 200 -o {output} 2> {log}

        """

rule make_bigwigs:
    input : "04aln_downsample/{sample}-downsample.sorted.bam", "04aln_downsample/{sample}-downsample.sorted.bam.bai"
    output: "07bigwig/{sample}.bw"
    log: "00log/{sample}.makebw"
    threads: 5
    params: jobname = "{sample}"
    message: "making bigwig for {input}"
    shell:
        """
    source activate root
        bamCoverage -b {input[0]} --normalizeUsingRPKM --binSize 30 --smoothLength 300 -p 5 --extendReads 200 -o {output} 2> {log}
        """



rule call_peaks_macs1:
    input: control = "04aln_downsample/{control}-downsample.sorted.bam", case="04aln_downsample/{case}-downsample.sorted.bam"
    output: "08peak_macs1/{case}_vs_{control}_macs1_peaks.bed", "08peak_macs1/{case}_vs_{control}_macs1_nomodel_peaks.bed"
    log: 
        macs1 = "00log/{case}_vs_{control}_call_peaks_macs1.log",
        macs1_nomodel = "00log/{case}_vs_{control}_call_peaks_macs1_nomodel.log"
    params:
        name1 = "{case}_vs_{control}_macs1",
        name2 = "{case}_vs_{control}_macs1_nomodel",
        jobname = "{case}"
    message: "call_peaks macs14 {input}: {threads} threads"
    shell:
        """
	   source activate root
        macs14 -t {input.case} \
            -c {input.control} --keep-dup all -f BAM -g {config[macs_g]} \
            --outdir 08peak_macs1 -n {params.name1} -p {config[macs_pvalue]} &> {log.macs1}
        
        # nomodel for macs14, shift-size will be 100 bp (e.g. fragment length of 200bp)
        # can get fragment length from the phantompeakqual. Now set it to 200 bp for all.
        macs14 -t {input.case} \
            -c {input.control} --keep-dup all -f BAM -g {config[macs_g]} \
            --outdir 08peak_macs1 -n {params.name2} --nomodel -p {config[macs_pvalue]} &> {log.macs1_nomodel}
        """

rule call_peaks_macs2:
    input: control = "04aln_downsample/{control}-downsample.sorted.bam", case="04aln_downsample/{case}-downsample.sorted.bam"
    output: bed = "09peak_macs2/{case}_vs_{control}_macs2_peaks.xls"
    log: "00log/{case}_vs_{control}_call_peaks_macs2.log"
    params:
        name = "{case}_vs_{control}_macs2",
        jobname = "{case}"
    message: "call_peaks macs2 {input}: {threads} threads"
    shell:
        """
       source activate root
       ## for macs2, when nomodel is set, --extsize is default to 200bp, this is the same as 2 * shift-size in macs14.
        macs2 callpeak -t {input.case} \
            -c {input.control} --keep-dup all -f BAM -g {config[macs2_g]} \
            --outdir 09peak_macs2 -n {params.name} -p {config[macs2_pvalue]} --broad --broad-cutoff {config[macs2_pvalue_broad]} --nomodel &> {log}
        """

rule multiQC:
    input : 
        expand("00log/{sample}.align", sample = ALL_SAMPLES),
        expand("03aln/{sample}.sorted.bam.flagstat", sample = ALL_SAMPLES),
        expand("02fqc/{sample}_fastqc.zip", sample = ALL_SAMPLES)
    output: "10multiQC/multiQC_log.html"
    log: "00log/multiqc.log"
    message: "multiqc for all logs"
    shell: 
        """
        multiqc 02fqc 03aln 00log -o 10multiQC -d -f -v -n multiQC_log 2> {log}

        """

## ROSE has to be run inside the folder where ROSE_main.py resides.
## symbolic link the rose folder to the snakefile folder can be one alternative solution.
rule superEnhancer:
    input : "04aln_downsample/{control}-downsample.sorted.bam", "04aln_downsample/{case}-downsample.sorted.bam", 
            "04aln_downsample/{control}-downsample.sorted.bam.bai", "04aln_downsample/{case}-downsample.sorted.bam.bai",
            "08peak_macs1/{case}_vs_{control}_macs1_peaks.bed"
    output: "11superEnhancer/{case}_vs_{control}-super/"
    log: "00log/{case}_superEnhancer.log"
    threads: 4
    params: 
            jobname = "{case}", 
            outputdir = os.path.dirname(srcdir("00log"))
    shell:
        """
        source activate root
        cd /scratch/genomic_med/apps/rose/default
        python ROSE_main.py -g {config[rose_g]} -i  {params.outputdir}/{input[4]} -r {params.outputdir}/{input[1]} -c {params.outputdir}/{input[0]} -o {params.outputdir}/{output}
        """

