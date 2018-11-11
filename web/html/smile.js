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
  var tmpLabels = [], tmpData1 = [], tmpData2 = [], tmpData3 = [];
  var tmpData4 = [], tmpData5 = [], tmpData6 = [], tmpData7 = [], tmpData8 = [];

  var meta = data.shift()
 
  var updatedAt = new Date(meta[0] * 1000);
  var atm = meta[1]

  for (var row in data) {
    tmpLabels.push(data[row][0]); // target_price
    tmpData1.push(data[row][1]); // o1.iv
    tmpData2.push(data[row][2]); // o1.price_time
    tmpData3.push(data[row][3]); // o2.iv
    tmpData4.push(data[row][4]); // o2.price_time
    tmpData5.push(data[row][5]); // o3.iv
    tmpData6.push(data[row][6]); // o3.price_time
    tmpData7.push(data[row][7]); // o4.iv
    tmpData8.push(data[row][8]); // o4.price_time
  };

  // 4)chart.jsで描画
  document.getElementById("loading").style.display ="none";
  var ctx = document.getElementById("chartCanvas").getContext("2d");
  var myChart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: tmpLabels,
      datasets: [
        { label: "1限月PUT IV", data: tmpData3, borderColor: "blue",
          backgroundColor: "blue", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "1限月CALL IV", data: tmpData1, borderColor: "red",
          backgroundColor: "red", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "2限月PUT IV", data: tmpData7, borderColor: "#87CEEB",
          backgroundColor: "#87CEEB", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "2限月CALL IV", data: tmpData5, borderColor: "#FFB6C1",
          backgroundColor: "#FFB6C1", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-1"},
        { label: "1限月PUT取引時刻", data: tmpData4, borderColor: "purple",
          backgroundColor: "purple", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
        { label: "1限月CALL取引時刻", data: tmpData2, borderColor: "green",
          backgroundColor: "green", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
        { label: "2限月PUT取引時刻", data: tmpData8, borderColor: "#D8BfD8",
          backgroundColor: "#D8BfD8", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
        { label: "2限月CALL取引時刻", data: tmpData6, borderColor: "#9FCC9F",
          backgroundColor: "#9FCC9F", fill: false, lineTension: 0,
          borderWidth: 1, pointRadius: 0, spanGaps: false, yAxisID: "y-axis-2"},
      ]
    },
    options: {
        responsive: true,
        title:{
            display:true,
            text: "スマイルカーブ(" + (updatedAt.getMonth() + 1) + '/' + updatedAt.getDate()  +' '
                          + updatedAt.getHours() + ':' + ("0"+updatedAt.getMinutes()).slice(-2) + ") ATM = " + atm,
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
            },
            {
                id: "y-axis-2",
                type: "linear",
                position: "right",
                ticks: {
                      callback: function(v) {var d=new Date(v * 1000); return  ("0"+d.getDate()).slice(-2)+'日'
                          +("0"+d.getHours()).slice(-2)+':'+("0"+d.getMinutes()).slice(-2)},
                },
                gridLines: {
                    drawOnChartArea: false,
                },
            },
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
