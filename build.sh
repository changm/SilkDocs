#!/bin/bash
pdflatex silk.tex
if [ $? -ne 0 ]
then
  exit
fi
pdflatex silk.tex
