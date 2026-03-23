model ElectionSimulation

global {

    // PARAMETERS
    string pref_model     <- "IC";
    string net_model      <- "ER";
    int    N_voters       <- 1000;
    int    scenario       <- 1;
    // 0=mostly strategic, 1=balanced, 2=mostly stubborn
    float  beta           <- 2.0;
    float  epsilon        <- 0.1;
    int    max_days       <- 60;
    int    run_id         <- 0;
    
    // Derived from scenario in init
    float  prop_stubborn  <- 0.0;
    float  prop_strategic <- 0.0;
    
    // Numeric encodings for surrogate model input
    // pref_model: IC=0, MALLOWS=1
    // net_model:  ER=0, BA=1
    int pref_code <- 0;
    int net_code  <- 0;

    // CONSTANTS
    int N_CANDIDATES <- 12;
    list<string> CANDIDATES <- [
        "Macron","LePen","Melenchon","Zemmour","Pecresse","Jadot",
        "Lassalle","Roussel","DupontAignan","Hidalgo","Poutou","Arthaud"
    ];
    
    // TRACKED INDICATORS
    float current_variance <- 0.0;
    float current_welfare  <- 0.0;
    int   current_changes  <- 0;
    map<int, VoterAgent> voter_map;

    init {
    	run_id <- int(replace(name, "Simulation", ""));
        
        // --- 1. Encode string parameters to numeric ---
        pref_code <- (pref_model = "IC") ? 0 : 1;
        net_code  <- (net_model  = "ER") ? 0 : 1;
        
        // --- 2. Set agent distribution from scenario ---
        if (scenario = 0) {
            prop_stubborn  <- 0.1;
            prop_strategic <- 0.7;
        } else if (scenario = 1) {
            prop_stubborn  <- 0.33;
            prop_strategic <- 0.34;
        } else {
            prop_stubborn  <- 0.6;
            prop_strategic <- 0.2;
        }

        // --- 3. Load preferences from CSV---
        string pref_path <- "../includes/preferences_" + pref_model + "_" + N_voters + ".csv";
        create VoterAgent from: csv_file(pref_path, ",", true) with: [
            voter_id :: int(get("voter_id")),
            rank_1   :: string(get("rank_1")),
            rank_2   :: string(get("rank_2")),
            rank_3   :: string(get("rank_3")),
            rank_4   :: string(get("rank_4")),
            rank_5   :: string(get("rank_5")),
            rank_6   :: string(get("rank_6")),
            rank_7   :: string(get("rank_7")),
            rank_8   :: string(get("rank_8")),
            rank_9   :: string(get("rank_9")),
            rank_10  :: string(get("rank_10")),
            rank_11  :: string(get("rank_11")),
            rank_12  :: string(get("rank_12"))
        ];
        ask VoterAgent {
            preference_ranking <- [rank_1,rank_2,rank_3,rank_4,
                                   rank_5,rank_6,rank_7,rank_8,
                                   rank_9,rank_10,rank_11,rank_12];
            favourite    <- preference_ranking[0];
            current_vote <- preference_ranking[0];
            voter_map[voter_id] <- self;
        }

        // --- 4. Load network from CSV ---
        string net_path <- "../includes/network_" + net_model + "_" + N_voters + ".csv";
        matrix net_data <- matrix(csv_file(net_path, ",", true));
        loop r from: 0 to: (net_data.rows - 1) {
            int src_id <- int(net_data[0, r]);
            int tgt_id <- int(net_data[1, r]);
            VoterAgent src <- voter_map[src_id];
            VoterAgent tgt <- voter_map[tgt_id];
            if (src != nil and tgt != nil) {
                src.neighbours <- src.neighbours + [tgt];
                tgt.neighbours <- tgt.neighbours + [src];
            }
        }

        // --- 5. Assign agent types ---
        ask VoterAgent {
            float r <- rnd(1.0);
            if      (r < prop_stubborn)                      { agent_type <- "stubborn"; }
            else if (r < prop_stubborn + prop_strategic)     { agent_type <- "strategic"; }
            else                                             { agent_type <- "mixed"; }
        }
    }

    string output_filename {
        return "../results/" + pref_model
               + "_" + net_model
               + "_sc" + scenario
               + "_b"  + beta
               + "_r"  + run_id    
               + ".csv";
    }

    reflex track_indicators when: (cycle >= 1 and cycle <= max_days) {
        map<string, int> tally <- map(CANDIDATES collect (each :: 0));
        ask VoterAgent { tally[current_vote] <- tally[current_vote] + 1; }

        list<float> scores <- CANDIDATES collect (float(tally[each]) / N_voters);
        float mu <- mean(scores);
        current_variance <- mean(scores collect ((each - mu)^2));

        string r2c1 <- CANDIDATES with_max_of (tally[each]);
        map<string, int> tally2 <- copy(tally);
        tally2[r2c1] <- -1;
        string r2c2 <- CANDIDATES with_max_of (tally2[each]);

        float total_welfare <- 0.0;
        loop v over: VoterAgent {
            int rank1 <- v.preference_ranking index_of r2c1;
            int rank2 <- v.preference_ranking index_of r2c2;
            int best  <- min([rank1, rank2]);
            total_welfare <- total_welfare + float(N_CANDIDATES - best);
        }
        current_welfare <- total_welfare / N_voters;

        current_changes <- VoterAgent count (each.changed_today);
        
        // Save numeric codes — surrogate model ready
        save [cycle, current_variance, current_welfare, current_changes,
              pref_code, net_code, N_voters, scenario,
              prop_stubborn, prop_strategic, beta, run_id]
            to: output_filename() format: "csv" rewrite: false;
    }

    reflex stop when: (cycle > max_days) {
        do pause;
    }
}

species VoterAgent {
    int              voter_id;
    string           rank_1;  string rank_2;  string rank_3;  string rank_4;
    string           rank_5;  string rank_6;  string rank_7;  string rank_8;
    string           rank_9;  string rank_10; string rank_11; string rank_12;
    list<string>     preference_ranking;
    string           favourite;
    string           current_vote;
    string           agent_type;
    list<VoterAgent> neighbours;
    bool             changed_today <- false;
    
    reflex decide {
        changed_today <- false;
        if (agent_type = "stubborn") {
            current_vote <- favourite;
            return;
        }

        if (length(neighbours) = 0) {
            current_vote <- favourite;
            return;
        }

        map<string, int> poll <- map(CANDIDATES collect (each :: 0));
        ask neighbours {
            poll[current_vote] <- poll[current_vote] + 1;
        }

        string top1 <- CANDIDATES with_max_of (poll[each]);
        map<string, int> poll_copy <- copy(poll);
        poll_copy[top1] <- -1;
        string top2 <- CANDIDATES with_max_of (poll_copy[each]);

        int s_fav  <- poll[favourite];
        int s_top2 <- poll[top2];
        int gap    <- s_top2 - s_fav;

        list<string> viable <- CANDIDATES where
            (poll[each] >= s_top2 * (1.0 - epsilon));
        
        string best_viable <- nil;
        loop pref over: preference_ranking {
            if (viable contains pref) {
                best_viable <- pref;
                break;
            }
        }
        if (best_viable = nil) { best_viable <- favourite; }

        if (agent_type = "strategic") {
            if (best_viable != current_vote) {
                current_vote  <- best_viable;
                changed_today <- true;
            }
        }
        else if (agent_type = "mixed") {
            float p_switch <- 1.0 / (1.0 + exp(- beta * float(gap)));
            if (rnd(1.0) < p_switch) {
                if (best_viable != current_vote) {
                    current_vote  <- best_viable;
                    changed_today <- true;
                }
            }
        }
    }
}

experiment GUI_Run type: gui {
    parameter "Preference model" var: pref_model  among: ["IC","MALLOWS"];
    parameter "Network model"    var: net_model   among: ["ER","BA"];
    parameter "Scenario"         var: scenario    among: [0, 1, 2];
    parameter "Beta"             var: beta        min: 0.1 max: 10.0 step: 0.5;
    
    output {
        display "Strategic Changes" refresh: every(1#cycle) {
            chart "Agents changing vote per day" type: series
                  x_label: "Day" y_label: "N agents" {
                data "Changes" value: current_changes color: #red;
            }
        }
        display "Social Welfare" refresh: every(1#cycle) {
            chart "Social welfare over time" type: series
                  x_label: "Day" y_label: "Welfare" {
                data "Welfare" value: current_welfare color: #blue;
            }
        }
        display "Variance" refresh: every(1#cycle) {
            chart "Score variance over time" type: series
                  x_label: "Day" y_label: "Variance" {
                data "Variance" value: current_variance color: #green;
            }
        }
        display "Vote Share" refresh: every(1#cycle) {
            chart "Candidate vote share" type: histogram
                  x_label: "Candidate" y_label: "Votes" {
                loop c over: CANDIDATES {
                    data c value: (VoterAgent count (each.current_vote = c));
                }
            }
        }
    }
}


experiment Batch_4Models type: batch
    repeat: 1
    until: (cycle > max_days)
    {
    parameter "Pref model"  var: pref_model among: ["IC","MALLOWS"];
    parameter "Net model"   var: net_model  among: ["ER","BA"];
    parameter "Scenario"    var: scenario   among: [0, 1, 2];
    parameter "Beta"        var: beta       among: [2.0, 5.0];
    parameter "N voters"    var: N_voters   among: [1000, 3000, 5000];
    parameter "Run ID"      var: run_id     among: [0,1,2,3,4,5,6,7,8,9];
}