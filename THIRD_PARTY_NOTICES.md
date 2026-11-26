# Third-party notices

## NSGA-III MATLAB routines

Mostapha Kalami Heris and Yarpiz, *NSGA-III in MATLAB (YPEA126)*, 2016. [Upstream project](https://github.com/smkalami/ypea126-nsga3) · [Project page](https://yarpiz.com/nsga3-ypea126).

The upstream routines carry their original headers. The full upstream license accompanies each copy: [33-bus](IEEE-33-Bus/MATLAB_Layer/LICENSE), [69-bus](IEEE-69-Bus/MATLAB_Layer/LICENSE). The project-specific entry point, feeder/traffic orchestration, MATLAB–Python coupling, and learned policies are separate contributions.

NSGA-III reference: K. Deb and H. Jain, *An Evolutionary Many-Objective Optimization Algorithm Using Reference-Point-Based Nondominated Sorting Approach, Part I: Solving Problems With Box Constraints*, 2014. [DOI](https://doi.org/10.1109/TEVC.2013.2281535).

## Test feeders

The 33- and 69-bus cases use the standard radial feeder benchmarks associated with M. E. Baran and F. F. Wu. [33-bus feeder reference](https://doi.org/10.1109/61.25627) · [69-bus feeder reference](https://doi.org/10.1109/61.19265). The case files use the MATPOWER case format. Scenario-specific topology additions, resource placement, hazard sequences, demand and solar profiles, traffic graphs, and trained weights were prepared for this project.

## Runtime dependencies

Install [YALMIP](https://yalmip.github.io/), MATLAB and its required toolboxes, [NumPy](https://numpy.org/), and [PyTorch](https://pytorch.org/) separately under their respective terms. Optional [Gurobi](https://www.gurobi.com/) requires a compatible installation and license.
