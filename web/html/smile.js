// 2) CSVから２次元配列に変換
function csv2Array(str) {
  var csvData = [];
  var lines = str.split("\n");
  for (var i = 0; i < lines.length; i++) {
    var cells = lines[i].split(",").map(x => x !== '' ? x : null);
    if(cells.length > 1) {
        csvData.push(cells);
    }
  }
  return csvData;
}

function drawChart(data) {
  // 3)chart.jsのdataset用の配列を用意
  var tmpLabels = [], tmpData1 = [], tmpData2 = [], tmpData3 = [], tmpData4 = [], tmpData5 = [];
  for (var row in data) {
    tmpLabels.push(data[row][0])
    tmpData1.push(data[row][1])
    tmpData2.push(data[row][2])
    tmpData3.push(data[row][3])
    tmpData4.push(data[row][4])
    tmpData5.push(data[row][5])
  };

  // 4)chart.jsで描画
  document.getElementById("loading").style.display ="none";
  var ctx = document.getElementById("chartCanvas").getContext("2d");
  var myChart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: tmpLabels,
      datasets: [
        { label: "PUT IV", data: tmpData2, borderColor: "blue", backgroundColor: "blue", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "PUT取引時刻", data: tmpData5, borderColor: "purple",
          backgroundColor: "purple", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
        { label: "CALL IV", data: tmpData1, borderColor: "red",
          backgroundColor: "red", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "CALL取引時刻", data: tmpData4, borderColor: "green",
          backgroundColor: "green", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
      ]
    },
    options: {
        responsive: true,
        title:{
            display:true,
            text: "スマイルカーブ(" + tmpData3[0] + ")",
        },
        scales: {
            xAxes: [{
                ticks: {
                    callback: function(value) { return (value%250 == 0) ? value : ''}
                }
            }],
            yAxes: [{
                id: "y-axis-1",
                type: "linear", 
                position: "left",
//                ticks: {
//                    max: 0.2,
//                    min: 0,
//                    stepSize: 0.1
//                },
            }, 
            {
                id: "y-axis-2",
                type: "linear", 
                position: "right",
                ticks: {
                      callback: function(v) {var d=new Date((v - 3600*9) * 1000); return  ("0"+d.getDate()).slice(-2)+'日'
                          +("0"+d.getHours()).slice(-2)+':'+("0"+d.getMinutes()).slice(-2)},
//                    max: 1.5,
//                    min: 0,
//                    stepSize: .5
                },
                gridLines: {
                    drawOnChartArea: false, 
                },
            },
//            {
//                id: "y-axis-3",
//                type: "linear", 
//                position: "right",
////                ticks: {
////                    max: 1.5,
////                    min: 0,
////                    stepSize: .5
////                },
//               gridLines: {
//                   drawOnChartArea: false, 
//               },
//            },
             ],
        }
    }
  });
}

function main() {
  // 1) ajaxでCSVファイルをロード
  var req = new XMLHttpRequest();
  var filePath = '../cgi-bin/smile.cgi';
  req.open("GET", filePath, true);
  req.onload = function() {
    // 2) CSVデータ変換の呼び出し
    data = csv2Array(req.responseText);
    // 3) chart.jsデータ準備、4) chart.js描画の呼び出し
    drawChart(data);
  }
  req.send(null);
}

main();
