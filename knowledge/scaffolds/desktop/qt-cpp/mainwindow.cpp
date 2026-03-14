#include "mainwindow.h"
#include "ui_mainwindow.h"

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
    , ui(new Ui::MainWindow)
    , clickCount(0)
{
    ui->setupUi(this);
    connect(ui->pushButton, &QPushButton::clicked, this, &MainWindow::onButtonClicked);
}

MainWindow::~MainWindow()
{
    delete ui;
}

void MainWindow::onButtonClicked()
{
    clickCount++;
    QString message = QString("Button clicked %1 time%2.")
                          .arg(clickCount)
                          .arg(clickCount == 1 ? "" : "s");
    ui->statusLabel->setText(message);
}
